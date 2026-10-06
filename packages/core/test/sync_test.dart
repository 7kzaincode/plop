import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
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
    // A folder is refused before it is zipped, and leaves nothing behind.
    final folder = Directory('${c.root.path}/big');
    File('${folder.path}/a.bin')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(600, 0));
    File('${folder.path}/b.bin').writeAsBytesSync(List.filled(600, 0));
    await expectLater(
      a.addPath(folder.path),
      throwsA(isA<ItemTooLargeException>().having((e) => e.size, 'size', 1200)),
    );
    await eventually(
      () => Directory('${c.root.path}/n0/${a.id}').listSync().isEmpty,
      reason: 'item dir left behind',
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

  test('peer item ids with path tricks are refused', () async {
    c = await Cluster.start(1);
    final s = c.nodes.single.store;
    RemoteItem remote(String id) => RemoteItem(
      id: id,
      name: 'x.txt',
      size: 1,
      mime: 'text/plain',
      kind: ItemKind.file,
      ttlMs: 1000,
    );
    for (final id in ['../../escape', 'a/b', r'..\x', '', 'x' * 65]) {
      expect(s.addRemote('p', 'p', remote(id)), isNull, reason: id);
    }
    expect(s.addRemote('p', 'p', remote(randomId())), isNotNull);

    // Even an id that slipped through stays a single path segment.
    final odd = ShelfItem(
      id: '../../escape',
      originId: 'p',
      originName: 'p',
      name: 'x.txt',
      size: 1,
      mime: 'text/plain',
      kind: ItemKind.file,
      expiresAt: DateTime.now(),
      ttl: Duration.zero,
    );
    final path = s.downloadPath(odd);
    expect(path, startsWith('${s.dir.path}${Platform.pathSeparator}'));
    expect(path.split(Platform.pathSeparator), isNot(contains('..')));
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

  test('folders travel as a zip and unpack to the same tree', () async {
    c = await Cluster.start(2, ttl: const Duration(seconds: 30));
    final [a, b] = c.nodes;
    final src = Directory('${c.root.path}/My Project');
    File('${src.path}/readme.md').createSync(recursive: true);
    File('${src.path}/readme.md').writeAsStringSync('hi');
    File('${src.path}/src/deep/main.dart').createSync(recursive: true);
    File(
      '${src.path}/src/deep/main.dart',
    ).writeAsBytesSync(List.filled(5000, 9));
    Directory('${src.path}/empty').createSync();

    final item = await a.addPath(src.path);
    expect(item.kind, ItemKind.folder);
    expect(item.name, 'My Project');
    // Really stored: the archive package buffers anything else whole.
    final input = InputFileStream(item.path!);
    for (final f in ZipDecoder().decodeStream(input)) {
      expect(f.compression, CompressionType.none, reason: f.name);
    }
    await input.close();

    await eventually(() => b.items.any((i) => i.isReady));
    final mirror = b.items.single;
    expect(mirror.kind, ItemKind.folder);
    expect(mirror.path, endsWith('My Project.zip'));

    final out = '${c.root.path}/out';
    await extractFolder(mirror.path!, out);
    expect(File('$out/readme.md').readAsStringSync(), 'hi');
    expect(File('$out/src/deep/main.dart').lengthSync(), 5000);
    expect(Directory('$out/empty').existsSync(), isTrue);
  });

  test('zipping a folder skips symlinks rather than following them', () async {
    c = await Cluster.start(1);
    final [a] = c.nodes;
    final outside = '${c.root.path}/outside';
    File('$outside/secret.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('secret');
    final src = Directory('${c.root.path}/dropped');
    File('${src.path}/a.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('a');
    Link('${src.path}/ext').createSync(outside);
    Link('${src.path}/secret.txt').createSync('$outside/secret.txt');
    Link('${src.path}/loop').createSync(src.path);

    final item = await a.addPath(src.path);
    final input = InputFileStream(item.path!);
    final names = ZipDecoder().decodeStream(input).map((f) => f.name);
    expect(names, ['a.txt']);
    await input.close();
  }, skip: Platform.isWindows ? 'creating symlinks needs admin rights' : false);

  test('saveTo writes outside the store and outlives the item', () async {
    c = await Cluster.start(
      2,
      ttl: const Duration(seconds: 2),
      eagerCopyBytes: 1024,
    );
    final [a, b] = c.nodes;
    final big = await a.addBytes(List.filled(3 * 1024 * 1024, 5), 'big.bin');
    await eventually(() => b.items.isNotEmpty);

    final dest = '${c.root.path}/saved.bin';
    await b.saveTo(itemKey(a.id, big.id), dest);
    expect(File(dest).lengthSync(), 3 * 1024 * 1024);
    expect(b.items.single.isReady, isFalse, reason: 'saveTo is not a mirror');

    await eventually(
      () => b.items.isEmpty,
      timeout: const Duration(seconds: 4),
    );
    expect(File(dest).existsSync(), isTrue);
  });

  test('lifetime can change; each item keeps its own', () async {
    c = await Cluster.start(2, ttl: const Duration(seconds: 30));
    final [a, b] = c.nodes;
    final first = await a.addText('first');
    a.ttl = const Duration(minutes: 10);
    final second = await a.addText('second');
    expect(first.ttl, const Duration(seconds: 30));
    expect(second.ttl, const Duration(minutes: 10));

    await eventually(() => b.items.length == 2);
    final m = b.store[itemKey(a.id, second.id)]!;
    expect(m.ttl.inSeconds, inInclusiveRange(595, 600));
  });

  test('unpacking a folder never writes outside the target', () async {
    c = await Cluster.start(1);
    final evil = Archive()
      ..add(ArchiveFile.bytes('../escaped.txt', [1, 2, 3]))
      ..add(ArchiveFile.bytes('ok.txt', [4]));
    final zip = File('${c.root.path}/evil.zip')
      ..writeAsBytesSync(ZipEncoder().encode(evil));
    final out = Directory('${c.root.path}/x/out');
    await extractFolder(zip.path, out.path);
    expect(File('${out.path}/ok.txt').existsSync(), isTrue);
    expect(File('${c.root.path}/x/escaped.txt').existsSync(), isFalse);
  });

  test('unpacking a folder ignores symlinks that chain outside', () async {
    c = await Cluster.start(1);
    // Made with Python's zipfile: a/b/l -> .., a/b/l/m -> ../../escaped,
    // then a/b/l/m/pwned.txt. Each link looks harmless on its own.
    final zip = File('${c.root.path}/evil.zip')
      ..writeAsBytesSync(
        base64.decode(
          'UEsDBBQAAAAAAAAAIQAcFgiWAgAAAAIAAAAFAAAAYS9iL2wuLlBLAwQUAAAAAAAAACEA'
          'vbvtlg0AAAANAAAABwAAAGEvYi9sL20uLi8uLi9lc2NhcGVkUEsDBBQAAAAAAKsGRl1+'
          'UwTZBQAAAAUAAAARAAAAYS9iL2wvbS9wd25lZC50eHRwd25lZFBLAQIUAxQAAAAAAAAA'
          'IQAcFgiWAgAAAAIAAAAFAAAAAAAAAAAAAAD/oQAAAABhL2IvbFBLAQIUAxQAAAAAAAAA'
          'IQC9u+2WDQAAAA0AAAAHAAAAAAAAAAAAAAD/oSUAAABhL2IvbC9tUEsBAhQDFAAAAAAA'
          'qwZGXX5TBNkFAAAABQAAABEAAAAAAAAAAAAAAIABVwAAAGEvYi9sL20vcHduZWQudHh0'
          'UEsFBgAAAAADAAMApwAAAIsAAAAAAA==',
        ),
      );
    final escaped = Directory('${c.root.path}/x/escaped')
      ..createSync(recursive: true);
    final out = Directory('${c.root.path}/x/out');
    await extractFolder(zip.path, out.path);
    expect(File('${escaped.path}/pwned.txt').existsSync(), isFalse);
    expect(
      out.listSync(recursive: true, followLinks: false).whereType<Link>(),
      isEmpty,
    );
  });
}
