import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// A zip entry stored the way plop sends them; ZipEncoder deflates otherwise.
ArchiveFile stored(String name, List<int> bytes) =>
    ArchiveFile.bytes(name, bytes)..compression = CompressionType.none;

/// A stored zip of [entries] files whose data regions overlap: each claims
/// every byte from its own header to the end of the data block, so the zip
/// unpacks to about [entries] times its size. Nothing in the format forbids
/// it, and the archive package does not check.
List<int> overlappingZip(int entries) {
  const header = 32, data = 4096; // 30-byte local header + a 2-char name
  final end = entries * header + data;
  final out = BytesBuilder();
  void u16(int v) => out.add([v & 0xff, v >> 8 & 0xff]);
  void u32(int v) => out.add([for (var i = 0; i < 32; i += 8) v >> i & 0xff]);
  for (var i = 0; i < entries; i++) {
    u32(0x04034b50); // local file header
    for (final v in [20, 0, 0, 0, 0]) {
      u16(v); // version, flags, method (stored), time, date
    }
    u32(0); // crc, not verified
    u32(end - header * (i + 1)); // compressed size
    u32(end - header * (i + 1)); // uncompressed size
    u16(2); // name length
    u16(0); // extra length
    out.add(ascii.encode('x$i'));
  }
  out.add(List.filled(data, 7));
  final cdStart = out.length;
  for (var i = 0; i < entries; i++) {
    u32(0x02014b50); // central directory entry
    for (final v in [20, 20, 0, 0, 0, 0]) {
      u16(v); // made by, needed, flags, method, time, date
    }
    u32(0);
    u32(end - header * (i + 1));
    u32(end - header * (i + 1));
    for (final v in [2, 0, 0, 0, 0]) {
      u16(v); // name, extra and comment lengths, disk, internal attributes
    }
    u32(0); // external attributes
    u32(header * i); // local header offset
    out.add(ascii.encode('x$i'));
  }
  final cdSize = out.length - cdStart;
  u32(0x06054b50); // end of central directory
  for (final v in [0, 0, entries, entries]) {
    u16(v); // disk, directory disk, entries on disk, entries total
  }
  u32(cdSize);
  u32(cdStart);
  u16(0); // comment length
  return out.takeBytes();
}

void main() {
  late Cluster c;
  tearDown(() => c.stop());

  test('A adds a file, B mirrors it, both drop it at expiry', () async {
    // Often the first test to run: the ttl outlasts the default wait for the
    // mirror, so a cold JIT cannot expire the item before it is checked.
    c = await Cluster.start(2, ttl: const Duration(seconds: 6));
    final [a, b] = c.nodes;
    final src = await tempFile(c.root, 'photo.png', 100 * 1024);
    final item = await a.addFile(src.path);

    await eventually(
      () => b.items.any((i) => i.id == item.id && i.isReady),
      reason: 'B did not mirror the item',
    );
    final mirror = b.items.single;
    expect(mirror.name, 'photo.png');
    expect(mirror.mime, 'image/png');
    expect(mirror.originName, 'node0');
    expect(await File(mirror.path!).readAsBytes(), await src.readAsBytes());
    // B's countdown is based on A's remaining time, not reset to a full TTL.
    expect(mirror.remaining, lessThanOrEqualTo(const Duration(seconds: 6)));

    await eventually(
      () => a.items.isEmpty && b.items.isEmpty,
      timeout: const Duration(seconds: 8),
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

  test('a shared file deleted or rewritten later leaves every shelf', () async {
    c = await Cluster.start(2, ttl: const Duration(seconds: 30));
    final [a, b] = c.nodes;
    final gone = await tempFile(c.root, 'gone.txt', 100);
    final grown = await tempFile(c.root, 'grown.txt', 100);
    await a.addFile(gone.path);
    await a.addFile(grown.path);
    await eventually(
      () => b.items.length == 2 && b.items.every((i) => i.isReady),
    );

    gone.deleteSync();
    grown.writeAsBytesSync([1, 2, 3], mode: FileMode.append);
    await eventually(
      () => a.items.isEmpty && b.items.isEmpty,
      reason: 'stale items still listed',
    );
  });

  test(
    'fetching a shared file that is gone drops it from the origin',
    () async {
      c = await Cluster.start(1, ttl: const Duration(seconds: 30));
      final [a] = c.nodes; // no peers, so no poll gets there first
      final src = await tempFile(c.root, 'gone.txt', 100);
      final item = await a.addFile(src.path);
      src.deleteSync();
      final res = await HttpClient()
          .getUrl(Uri.parse('http://127.0.0.1:${a.port}/v1/items/${item.id}'))
          .then((r) => r.close());
      expect(res.statusCode, 404);
      expect(a.items, isEmpty);
    },
  );

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

  test('safeFileName keeps dotfiles and refuses only . and ..', () async {
    c = await Cluster.start(1);
    expect(safeFileName('.env'), '.env');
    expect(safeFileName('...hidden'), '...hidden');
    expect(safeFileName('a:b?.txt'), 'a_b_.txt');
    for (final name in ['', '.', '..', '...', ' .. ']) {
      expect(safeFileName(name), 'file', reason: '"$name"');
    }
    expect(safeFileName('../x'), '.._x');
    expect(safeFileName(r'..\x'), '.._x');
  });

  test('odd remote fields are refused or clamped', () async {
    c = await Cluster.start(1);
    final s = c.nodes.single.store;
    Map<String, dynamic> json({
      Object size = 1,
      Object ttlMs = 1000,
      String name = 'x',
    }) => {'id': randomId(), 'name': name, 'size': size, 'ttlMs': ttlMs};
    ShelfItem? add(Map<String, dynamic> j) =>
        s.addRemote('p', 'p', RemoteItem.fromJson(j));
    expect(add(json(size: -5)), isNull);
    expect(add(json(size: 0)), isNotNull, reason: 'an empty file is legal');
    // toInt() saturates to 2^63-1, which Duration would wrap to -1 ms.
    final forever = add(json(ttlMs: 1e300))!;
    expect(forever.ttl, ShelfStore.maxRemoteTtl);
    expect(forever.expiresAt.isAfter(DateTime.now()), isTrue);
    final long = add(json(name: 'n' * 10000))!;
    expect(long.name.length, ShelfStore.maxNameLength);
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

  test('folders keep the executable bit, and only that', () async {
    c = await Cluster.start(1);
    final [a] = c.nodes;
    final src = Directory('${c.root.path}/tool');
    File('${src.path}/run.sh')
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\n');
    File('${src.path}/notes.txt').writeAsStringSync('hi');
    // Dart has no chmod. 0700 and 0600: only the x bit should come through,
    // the rw bits of both should be the receiver's own.
    await Process.run('chmod', ['700', '${src.path}/run.sh']);
    await Process.run('chmod', ['600', '${src.path}/notes.txt']);

    final item = await a.addPath(src.path);
    final out = '${c.root.path}/out';
    await extractFolder(item.path!, out);
    int perms(String name) => File('$out/$name').statSync().mode & 0x1ff;
    expect(perms('run.sh') & 0x40, 0x40, reason: 'u+x lost');
    expect(perms('run.sh') & 0x1b6, perms('notes.txt'), reason: 'rw differ');
    expect(perms('notes.txt') & 0x49, 0, reason: 'x bit invented');
    // The archive itself carries only 0755/0644, never the sender's 0700/0600.
    final zipped = ZipDecoder().decodeStream(InputFileStream(item.path!));
    final modes = {for (final f in zipped) f.name: f.mode & 0x1ff};
    expect(modes['run.sh'], 0x1ed);
    expect(modes['notes.txt'], 0x1a4);
    // Readable by all under the usual umask, so executable by all too.
    if (perms('notes.txt') == 0x1a4) expect(perms('run.sh'), 0x1ed);
  }, skip: Platform.isWindows ? 'no executable bit' : false);

  test('links that stay inside a folder travel as copies', () async {
    c = await Cluster.start(1);
    final [a] = c.nodes;
    final src = Directory('${c.root.path}/dropped');
    File('${src.path}/Versions/A/lib')
      ..createSync(recursive: true)
      ..writeAsStringSync('lib');
    Link('${src.path}/Versions/Current').createSync('A');
    Link('${src.path}/latest').createSync('Versions/A/lib');
    Link('${src.path}/gone').createSync('missing');
    Link('${src.path}/up').createSync('..');

    final item = await a.addPath(src.path);
    final input = InputFileStream(item.path!);
    final names = ZipDecoder().decodeStream(input).map((f) => f.name);
    expect(names, {
      'Versions/',
      'Versions/A/',
      'Versions/A/lib',
      'Versions/Current/',
      'Versions/Current/lib',
      'latest',
    });
    await input.close();

    final out = '${c.root.path}/out';
    await extractFolder(item.path!, out);
    for (final p in ['$out/Versions/Current/lib', '$out/latest']) {
      expect(
        FileSystemEntity.typeSync(p, followLinks: false),
        FileSystemEntityType.file,
        reason: p,
      );
      expect(File(p).readAsStringSync(), 'lib');
    }
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

  test('the sender learns which peers have received an item', () async {
    c = await Cluster.start(
      2,
      ttl: const Duration(seconds: 30),
      eagerCopyBytes: 1024,
    );
    final [a, b] = c.nodes;
    final small = await a.addBytes(List.filled(100, 1), 'small.bin');
    final big = await a.addBytes(List.filled(5000, 2), 'big.bin');
    // The eager copy counts as received; the big one not until grabbed.
    await eventually(() => small.receivedBy.contains(b.id));
    await eventually(() => b.store[big.key] != null);
    expect(big.receivedBy, isEmpty);
    expect(a.peerName(b.id), 'node1');

    // A transfer that fails is not reported; one that lands is.
    final blocker = File('${c.root.path}/blocker')..createSync();
    await expectLater(
      b.saveTo(big.key, '${blocker.path}/big.bin'),
      throwsA(isA<FileSystemException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(big.receivedBy, isEmpty);
    await b.saveTo(big.key, '${c.root.path}/big.bin');
    await eventually(() => big.receivedBy.contains(b.id));

    // Changes fire only for news.
    var fired = 0;
    final sub = a.changes.listen((_) => fired++);
    addTearDown(sub.cancel);
    a.store.markReceived(small.key, 'x');
    a.store.markReceived(small.key, 'x');
    await Future<void>.delayed(Duration.zero);
    expect(fired, 1);
  });

  test('a failed saveTo does not leave progress showing', () async {
    c = await Cluster.start(
      2,
      ttl: const Duration(seconds: 30),
      eagerCopyBytes: 1024,
    );
    final [a, b] = c.nodes;
    final big = await a.addBytes(List.filled(5000, 5), 'big.bin');
    await eventually(() => b.items.isNotEmpty);
    final key = itemKey(a.id, big.id);
    // A file where a folder should be makes the download fail.
    final blocker = File('${c.root.path}/blocker')..createSync();
    await expectLater(
      b.saveTo(key, '${blocker.path}/big.bin'),
      throwsA(isA<FileSystemException>()),
    );
    expect(b.store[key]!.progress, isNull);
  });

  test('a failed download leaves no .part behind', () async {
    c = await Cluster.start(1);
    final liar = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => liar.close(force: true));
    liar.listen((req) {
      final res = req.response;
      if (req.uri.path.endsWith('/gone')) {
        res.statusCode = HttpStatus.notFound;
      } else {
        // 'ok' sends what was advertised; anything else sends more.
        final n = req.uri.path.endsWith('/ok') ? 1000 : 64 * 1024;
        res.add(List.filled(n, 1));
      }
      res.close().ignore(); // the client may hang up first
    });
    final base = Uri.parse('http://127.0.0.1:${liar.port}');
    final client = NodeClient();
    addTearDown(client.close);
    final dest = '${c.root.path}/got.bin';
    for (final id in ['x', 'gone']) {
      await expectLater(
        client.download(base, id, dest, expectedSize: 1000),
        throwsA(isA<HttpException>()),
      );
      expect(File('$dest.part').existsSync(), isFalse, reason: id);
      expect(File(dest).existsSync(), isFalse, reason: id);
    }
    // The bytes all arrived but the rename failed, here onto a folder.
    final blocked = Directory('${c.root.path}/blocked.bin')..createSync();
    await expectLater(
      client.download(base, 'ok', blocked.path, expectedSize: 1000),
      throwsA(isA<FileSystemException>()),
    );
    expect(File('${blocked.path}.part').existsSync(), isFalse);
  });

  test('an endless item list is cut off, not buffered', () async {
    c = await Cluster.start(1);
    final liar = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => liar.close(force: true));
    var sent = 0;
    liar.listen((req) async {
      final res = req.response..headers.contentType = ContentType.json;
      // A JSON list that never ends, paced by the socket. The bound only
      // guarantees the test ends if the client fails to hang up.
      res.write('[');
      final pad = List.filled(64 * 1024, 0x20);
      try {
        while (sent < 64 * 1024 * 1024) {
          res.add(pad);
          sent += pad.length;
          await res.flush();
        }
      } catch (_) {
        // The client hung up.
      }
      res.close().ignore();
    });
    final client = NodeClient();
    addTearDown(client.close);
    final clock = Stopwatch()..start();
    await expectLater(
      client.fetchList(Uri.parse('http://127.0.0.1:${liar.port}'), 'me'),
      throwsA(isA<HttpException>()),
    );
    expect(
      clock.elapsed,
      lessThan(const Duration(seconds: 3)),
      reason: 'should give up on the size cap, not the timeout',
    );
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

  test('the shelf is ordered by arrival, not by expiry', () async {
    c = await Cluster.start(2, ttl: const Duration(hours: 1));
    final [a, b] = c.nodes;
    final own = await b.addText('b first');
    await eventually(() => a.items.isNotEmpty);
    final long = await a.addText('an hour');
    a.ttl = const Duration(seconds: 30);
    final short = await a.addText('half a minute');
    // The 30 s item expires long before the others but is the newest.
    expect(a.items.map((i) => i.id), [short.id, long.id, own.id]);
    expect(
      DateTime.now().difference(short.addedAt),
      lessThan(const Duration(seconds: 5)),
    );

    // Mirrors arrive in A's order, so B's newest is A's newest too.
    await eventually(() => b.items.length == 3);
    expect(b.items.map((i) => i.id), [short.id, long.id, own.id]);
  });

  test('unpacking a folder never writes outside the target', () async {
    c = await Cluster.start(1);
    final evil = Archive()
      ..add(stored('../escaped.txt', [1, 2, 3]))
      ..add(stored('ok.txt', [4]));
    final zip = File('${c.root.path}/evil.zip')
      ..writeAsBytesSync(ZipEncoder().encode(evil));
    final out = Directory('${c.root.path}/x/out');
    await extractFolder(zip.path, out.path);
    expect(File('${out.path}/ok.txt').existsSync(), isTrue);
    expect(File('${c.root.path}/x/escaped.txt').existsSync(), isFalse);
  });

  test('unpacking a folder sanitises each name like a single file', () async {
    c = await Cluster.start(1);
    final odd = Archive()
      ..add(stored('dir?/a:b?.txt', [1]))
      ..add(stored('dir?/.gitignore', [2]));
    final zip = File('${c.root.path}/odd.zip')
      ..writeAsBytesSync(ZipEncoder().encode(odd));
    final out = '${c.root.path}/out';
    await extractFolder(zip.path, out);
    expect(File('$out/dir_/a_b_.txt').existsSync(), isTrue);
    expect(File('$out/dir_/.gitignore').existsSync(), isTrue);
  });

  test('a folder zip that inflates is refused and leaves nothing', () async {
    c = await Cluster.start(1);
    // Deflated (the encoder's default): 4 MB of zeros in a few KB.
    final bomb = Archive()
      ..add(stored('readme.txt', [1]))
      ..add(ArchiveFile.bytes('zeros.bin', List.filled(4 << 20, 0)));
    final zip = File('${c.root.path}/bomb.zip')
      ..writeAsBytesSync(ZipEncoder().encode(bomb));
    expect(zip.lengthSync(), lessThan(64 * 1024), reason: 'not a bomb');
    // By message: a malformed zip is a FormatException too (ArchiveException).
    Matcher refused(String why) => throwsA(
      isA<FormatException>().having((e) => e.message, 'message', contains(why)),
    );
    final out = Directory('${c.root.path}/x/out');
    await expectLater(extractFolder(zip.path, out.path), refused('compressed'));
    expect(out.existsSync(), isFalse, reason: 'half a folder left behind');

    // Stored entries can still overlap, so one block unpacks many times.
    final overlap = File('${c.root.path}/overlap.zip')
      ..writeAsBytesSync(overlappingZip(8));
    await expectLater(
      extractFolder(overlap.path, out.path),
      refused('more than its size'),
    );
    expect(out.existsSync(), isFalse);

    // A folder the receiver already had is not swept away with the failure.
    final mine = Directory('${c.root.path}/mine')..createSync();
    File('${mine.path}/keep.txt').writeAsStringSync('keep');
    await expectLater(
      extractFolder(zip.path, mine.path),
      refused('compressed'),
    );
    expect(File('${mine.path}/keep.txt').existsSync(), isTrue);
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

  test('a peer we reach that never reaches us is flagged one-way', () async {
    c = await Cluster.start(2, ttl: const Duration(seconds: 30));
    final [a, b] = c.nodes;
    // Only A knows about B, so B never polls A.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(a.peers.map((p) => p.id), [b.id]);
    expect(a.oneWay, isEmpty, reason: 'needs time before it is flagged');
    // Pretend A has been reaching B for longer than the grace period.
    a.server.seenBy.clear();
    final okSince = a.engine.okSince(b.id)!;
    expect(
      DateTime.now().difference(okSince),
      lessThan(const Duration(seconds: 5)),
    );
    // Simulate time passing by dating the record back.
    a.engine.debugSetOkSince(
      b.id,
      DateTime.now().subtract(const Duration(seconds: 20)),
    );
    expect(a.oneWay.map((p) => p.id), [b.id]);

    // B reached A long ago, slept, and has just become reachable again: the
    // grace period starts over rather than flagging it on the spot.
    a.server.seenBy[b.id] = DateTime.now().subtract(
      const Duration(minutes: 10),
    );
    a.engine.debugSetOkSince(b.id, DateTime.now());
    expect(a.oneWay, isEmpty, reason: 'stale seenBy must not win');
    a.engine.debugSetOkSince(
      b.id,
      DateTime.now().subtract(const Duration(seconds: 20)),
    );
    expect(a.oneWay.map((p) => p.id), [b.id], reason: 'both stale: flagged');

    // Once B polls A, the flag clears.
    c.connect(1, 0);
    await eventually(() => a.oneWay.isEmpty && b.peers.isNotEmpty);
  });

  test('revive re-binds a closed server and re-polls peers', () async {
    c = await Cluster.start(2, ttl: const Duration(seconds: 30));
    final [a, b] = c.nodes;
    await eventually(() => a.peers.isNotEmpty && b.peers.isNotEmpty);
    final port = a.port;
    // The OS reclaimed the socket while the app was suspended.
    await a.server.stop();
    await a.revive();
    expect(a.port, port, reason: 'same port when it is still free');
    await b.addText('after revive');
    await eventually(() => a.items.any((i) => i.name == 'after revive'));
    // B can fetch from A again too.
    await a.addText('from a');
    await eventually(() => b.items.any((i) => i.name == 'from a'));
  });

  test(
    'an item still downloading survives its expiry until it lands',
    () async {
      c = await Cluster.start(
        2,
        ttl: const Duration(seconds: 2),
        eagerCopyBytes: 1024,
      );
      final [a, b] = c.nodes;
      final big = await a.addBytes(List.filled(2 * 1024 * 1024, 3), 'big.bin');
      final key = itemKey(a.id, big.id);
      await eventually(() => b.store[key] != null);
      // Hold the row in "transferring" past its expiry.
      b.store.setProgress(key, 0.5);
      await Future<void>.delayed(const Duration(milliseconds: 2600));
      expect(b.store[key], isNotNull, reason: 'kept while transferring');
      expect(a.store[big.key], isNull, reason: 'the origin expired normally');
      b.store.setProgress(key, null);
      await eventually(
        () => b.store[key] == null,
        timeout: const Duration(seconds: 3),
      );
    },
  );
}
