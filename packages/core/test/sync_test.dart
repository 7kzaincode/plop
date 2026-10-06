import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:plop_core/plop_core.dart';
import 'package:test/test.dart';

/// Several nodes on localhost, each told about the others via
/// [StaticDiscovery].
class Cluster {
  Cluster._(this.nodes, this.discoveries, this.root);

  final List<PlopNode> nodes;
  final List<StaticDiscovery> discoveries;
  final Directory root;

  static Future<Cluster> start(
    int n, {
    Duration ttl = const Duration(seconds: 3),
    int eagerCopyBytes = defaultEagerCopyBytes,
    int maxItemBytes = defaultMaxItemBytes,
  }) async {
    final root = await Directory.systemTemp.createTemp('plop_test');
    final discoveries = List.generate(n, (_) => StaticDiscovery());
    final nodes = <PlopNode>[];
    for (var i = 0; i < n; i++) {
      nodes.add(
        await PlopNode.start(
          dir: Directory('${root.path}/n$i'),
          discovery: discoveries[i],
          name: 'node$i',
          ttl: ttl,
          eagerCopyBytes: eagerCopyBytes,
          maxItemBytes: maxItemBytes,
          pollInterval: const Duration(milliseconds: 300),
        ),
      );
    }
    final c = Cluster._(nodes, discoveries, root);
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        if (i != j) c.connect(i, j);
      }
    }
    return c;
  }

  Peer peer(int i) => Peer(
    id: nodes[i].id,
    name: 'node$i',
    hosts: ['127.0.0.1'],
    port: nodes[i].port,
  );

  /// Tells node [i] about node [j].
  void connect(int i, int j) => discoveries[i].add(peer(j));

  Future<void> stop() async {
    for (final n in nodes) {
      await n.stop();
    }
    await root.delete(recursive: true);
  }
}

Future<void> eventually(
  bool Function() check, {
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) async {
  final end = DateTime.now().add(timeout);
  while (!check()) {
    if (DateTime.now().isAfter(end)) fail(reason ?? 'condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<File> tempFile(Directory root, String name, int size) async {
  final f = File('${root.path}/$name');
  await f.writeAsBytes(List.generate(size, (i) => i % 251));
  return f;
}

void main() {
  late Cluster c;
  tearDown(() => c.stop());

  test('A adds a file, B mirrors it, both drop it at expiry', () async {
    c = await Cluster.start(2, ttl: const Duration(seconds: 3));
    final [a, b] = c.nodes;
    final src = await tempFile(c.root, 'photo.png', 100 * 1024);
    final item = await a.addFile(src.path);

    await eventually(
      () => b.items.any((i) => i.id == item.id && i.isReady),
      timeout: const Duration(seconds: 2),
      reason: 'B did not mirror the item',
    );
    final mirror = b.items.single;
    expect(mirror.name, 'photo.png');
    expect(mirror.mime, 'image/png');
    expect(mirror.originName, 'node0');
    expect(await File(mirror.path!).readAsBytes(), await src.readAsBytes());
    // B's countdown is based on A's remaining time, not reset to a full TTL.
    expect(mirror.remaining, lessThanOrEqualTo(const Duration(seconds: 3)));

    await eventually(
      () => a.items.isEmpty && b.items.isEmpty,
      timeout: const Duration(seconds: 4),
      reason: 'item did not expire on both nodes',
    );
    expect(
      File(mirror.path!).existsSync(),
      isFalse,
      reason: 'mirror copy left behind',
    );
    expect(
      src.existsSync(),
      isTrue,
      reason: "user's own file must not be deleted",
    );
  });

  test('items over the eager cap are listed but only fetched on tap', () async {
    c = await Cluster.start(
      2,
      ttl: const Duration(seconds: 30),
      eagerCopyBytes: 1024,
    );
    final [a, b] = c.nodes;
    final big = await a.addBytes(List.filled(10 * 1024, 7), 'big.bin');
    final small = await a.addBytes(List.filled(512, 1), 'small.bin');

    await eventually(() => b.items.length == 2);
    final key = itemKey(a.id, big.id);
    await eventually(() => b.store[itemKey(a.id, small.id)]!.isReady);
    // Give an erroneous eager copy time to happen.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(b.store[key]!.isReady, isFalse);

    final path = await b.fetch(key);
    expect(await File(path).length(), 10 * 1024);
    expect(b.store[key]!.isReady, isTrue);
  });

  test('text items arrive with their content', () async {
    c = await Cluster.start(2, ttl: const Duration(seconds: 30));
    final [a, b] = c.nodes;
    await a.addText('hello from A\nsecond line');
    await eventually(() => b.items.any((i) => i.isReady));
    final t = b.items.single;
    expect(t.kind, ItemKind.text);
    expect(t.name, 'hello from A');
    expect(await File(t.path!).readAsString(), 'hello from A\nsecond line');
  });

  test('mirrors are not re-served', () async {
    c = await Cluster.start(3, ttl: const Duration(seconds: 30));
    final [a, b, cc] = c.nodes;
    final item = await a.addText('x');
    await eventually(() => b.items.isNotEmpty && cc.items.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(cc.items.single.originId, a.id);
    expect(b.items.single.originId, a.id);

    final res = await HttpClient()
        .getUrl(Uri.parse('http://127.0.0.1:${b.port}/v1/items'))
        .then((r) => r.close());
    expect(jsonDecode(await utf8.decodeStream(res)), isEmpty);
    final miss = await HttpClient()
        .getUrl(Uri.parse('http://127.0.0.1:${b.port}/v1/items/${item.id}'))
        .then((r) => r.close());
    expect(miss.statusCode, 404);
  });

  test(
    'when a peer goes away, copied items stay and uncopied ones go',
    () async {
      c = await Cluster.start(
        2,
        ttl: const Duration(seconds: 30),
        eagerCopyBytes: 1024,
      );
      final [a, b] = c.nodes;
      await a.addBytes(List.filled(100, 1), 'small.bin');
      await a.addBytes(List.filled(5000, 1), 'big.bin');
      await eventually(
        () => b.items.length == 2 && b.items.any((i) => i.isReady),
      );

      c.discoveries[1].remove(a.id);
      await eventually(() => b.items.length == 1);
      expect(b.items.single.name, 'small.bin');
      expect(b.items.single.isReady, isTrue);
    },
  );

  test('an unreachable peer counts as gone after repeated failures', () async {
    c = await Cluster.start(
      2,
      ttl: const Duration(seconds: 30),
      eagerCopyBytes: 1024,
    );
    final [a, b] = c.nodes;
    await a.addBytes(List.filled(5000, 1), 'big.bin');
    await eventually(() => b.items.length == 1);
    expect(b.peers.map((p) => p.id), [a.id]);

    await a.server.stop();
    await eventually(() => b.items.isEmpty && b.peers.isEmpty);
  });

  test('nudges propagate quickly even with slow polling', () async {
    final root = await Directory.systemTemp.createTemp('plop_test');
    final da = StaticDiscovery(), db = StaticDiscovery();
    final a = await PlopNode.start(
      dir: Directory('${root.path}/a'),
      discovery: da,
      name: 'a',
      pollInterval: const Duration(minutes: 1),
    );
    final b = await PlopNode.start(
      dir: Directory('${root.path}/b'),
      discovery: db,
      name: 'b',
      pollInterval: const Duration(minutes: 1),
    );
    c = Cluster._([a, b], [da, db], root);
    c.connect(0, 1);
    c.connect(1, 0);
    await Future<void>.delayed(const Duration(milliseconds: 300));

    await a.addText('nudge me');
    await eventually(
      () => b.items.isNotEmpty,
      timeout: const Duration(seconds: 1),
      reason: 'nudge did not trigger a re-fetch',
    );
    a.remove(a.items.single.key);
    await eventually(
      () => b.items.isEmpty,
      timeout: const Duration(seconds: 1),
    );
  });

  test('hard cap rejects local adds and ignores remote ones', () async {
    c = await Cluster.start(2, maxItemBytes: 1000);
    final [a, b] = c.nodes;
    expect(
      () => a.addBytes(List.filled(1001, 0), 'x.bin'),
      throwsA(isA<ItemTooLargeException>()),
    );

    // A peer that ignores the cap still cannot make B mirror an oversized item.
    b.store.addRemote(
      'evil',
      'evil',
      RemoteItem(
        id: 'z',
        name: 'z',
        size: 5000,
        mime: 'x',
        kind: ItemKind.file,
        ttlMs: 1000,
      ),
    );
    expect(b.items, isEmpty);
  });

  test('peer names with path tricks stay inside the store dir', () async {
    c = await Cluster.start(2, ttl: const Duration(seconds: 30));
    final [a, b] = c.nodes;
    await a.addBytes([1, 2, 3], '../../escape.txt');
    await eventually(() => b.items.any((i) => i.isReady));
    final path = b.items.single.path!;
    expect(path, startsWith('${c.root.path}/n1/'));
    expect(path, endsWith('escape.txt'));
    expect(path.split('/'), isNot(contains('..')));
  });

  test('a node ignores its own advertisement', () async {
    c = await Cluster.start(1, ttl: const Duration(seconds: 30));
    final [a] = c.nodes;
    c.discoveries[0].add(c.peer(0));
    await a.addText('mine');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(a.items, hasLength(1));
    expect(a.peers, isEmpty);
  });

  test('wipes its directory on start', () async {
    final root = await Directory.systemTemp.createTemp('plop_test');
    final stale = File('${root.path}/n/leftover.bin')
      ..createSync(recursive: true);
    final d = StaticDiscovery();
    final n = await PlopNode.start(
      dir: Directory('${root.path}/n'),
      discovery: d,
      name: 'n',
    );
    c = Cluster._([n], [d], root);
    expect(stale.existsSync(), isFalse);
  });
}
