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
    Duration eagerDeadline = defaultEagerDeadline,
    int maxItemBytes = defaultMaxItemBytes,
    NodeClient? Function(int i)? client,
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
          eagerDeadline: eagerDeadline,
          maxItemBytes: maxItemBytes,
          pollInterval: const Duration(milliseconds: 300),
          client: client?.call(i),
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

/// A [NodeClient] that counts the downloads it has running at once, and
/// fails those that [fails] picks by file name and attempt number.
class CountingClient extends NodeClient {
  CountingClient(this.fails);

  final bool Function(String name, int attempt) fails;
  var inFlight = 0, maxInFlight = 0;

  /// The same, per sender, by its port.
  final inFlightByPort = <int, int>{}, maxInFlightByPort = <int, int>{};

  /// Download attempts by file name.
  final calls = <String, int>{};

  @override
  Future<void> download(
    Uri base,
    String id,
    String destPath, {
    required int expectedSize,
    void Function(int received)? onProgress,
    Future<void>? cutOff,
  }) async {
    final name = destPath.split(Platform.pathSeparator).last;
    final attempt = calls[name] = (calls[name] ?? 0) + 1;
    if (++inFlight > maxInFlight) maxInFlight = inFlight;
    final port = base.port;
    final here = inFlightByPort[port] = (inFlightByPort[port] ?? 0) + 1;
    if (here > (maxInFlightByPort[port] ?? 0)) maxInFlightByPort[port] = here;
    try {
      // Long enough for downloads to overlap if nothing holds them back.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (fails(name, attempt)) throw const HttpException('failed by the test');
      await super.download(
        base,
        id,
        destPath,
        expectedSize: expectedSize,
        onProgress: onProgress,
        cutOff: cutOff,
      );
    } finally {
      inFlight--;
      inFlightByPort[port] = inFlightByPort[port]! - 1;
    }
  }
}

/// A fake peer listing items of the given sizes by id, whose bytes it sends
/// one every [step]: slow enough to hold a download for a long while, never
/// so slow that the client's stall timeout trips. A sender on a bad link,
/// or a hostile one.
class Trickler {
  Trickler._(this._server, this.sizes, this.step);

  static Future<Trickler> start(
    Map<String, int> sizes, {
    Duration step = const Duration(milliseconds: 100),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final t = Trickler._(server, sizes, step);
    server.listen(t._handle);
    return t;
  }

  final HttpServer _server;
  final Map<String, int> sizes;
  final Duration step;
  var _closed = false;

  /// Download requests so far, by item id.
  final requests = <String, int>{};

  int get port => _server.port;

  Peer get peer =>
      Peer(id: 'trickler', name: 'trickler', hosts: ['127.0.0.1'], port: port);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      switch (req.uri.pathSegments) {
        case ['v1', 'items']:
          res.headers.contentType = ContentType.json;
          res.write(
            jsonEncode([
              for (final MapEntry(:key, :value) in sizes.entries)
                {'id': key, 'name': '$key.bin', 'size': value, 'ttlMs': 60000},
            ]),
          );
        case ['v1', 'items', final id] when req.method == 'GET':
          requests[id] = (requests[id] ?? 0) + 1;
          final size = sizes[id] ?? 0;
          res.contentLength = size;
          // Paced by a timer: dart:io hides a hang-up from the server, so
          // this goes on after the client gives up, until [close].
          for (var i = 0; i < size && !_closed; i++) {
            res.add([i % 251]);
            await res.flush();
            await Future<void>.delayed(step);
          }
        default:
          res.statusCode = HttpStatus.notFound;
      }
      await res.close();
    } catch (_) {
      // Cut short by [close].
    }
  }

  Future<void> close() async {
    _closed = true;
    await _server.close(force: true);
  }
}

/// A [NodeClient] whose downloads wait for [gate] before they start.
class GatedClient extends NodeClient {
  GatedClient(this.gate);

  final Future<void> gate;

  @override
  Future<void> download(
    Uri base,
    String id,
    String destPath, {
    required int expectedSize,
    void Function(int received)? onProgress,
    Future<void>? cutOff,
  }) async {
    await gate;
    await super.download(
      base,
      id,
      destPath,
      expectedSize: expectedSize,
      onProgress: onProgress,
      cutOff: cutOff,
    );
  }
}

/// Stats of [path] hang until [release] completes, as on a share whose
/// server went away. Others go through.
final class HangingStat extends IOOverrides {
  HangingStat(this.path);

  final String path;
  final release = Completer<void>();

  /// Stats of [path] asked for so far.
  var hung = 0;

  @override
  Future<FileStat> stat(String path) {
    if (path != this.path) return super.stat(path);
    hung++;
    return release.future.then((_) => super.stat(path));
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

/// A zip written field by field, for entries ZipEncoder cannot make: it
/// always records MS-DOS as the maker, so a Unix symlink is out of reach.
/// [data] is the entry as it sits in the zip, packed by [method]; [size] is
/// what it unpacks to and [mode] its Unix mode. [localFlags] and
/// [centralFlags] are every entry's general-purpose bits in each header.
List<int> handZip(
  List<({String name, List<int> data, int method, int size, int mode})> files, {
  int localFlags = 0,
  int centralFlags = 0,
}) {
  final out = BytesBuilder();
  void u16(int v) => out.add([v & 0xff, v >> 8 & 0xff]);
  void u32(int v) => out.add([for (var i = 0; i < 32; i += 8) v >> i & 0xff]);
  final offsets = <int>[];
  for (final f in files) {
    offsets.add(out.length);
    u32(0x04034b50); // local file header
    for (final v in [20, localFlags, f.method, 0, 0]) {
      u16(v); // version, flags, method, time, date
    }
    u32(0); // crc, not verified
    u32(f.data.length);
    u32(f.size);
    u16(f.name.length);
    u16(0); // extra length
    out
      ..add(ascii.encode(f.name))
      ..add(f.data);
  }
  final cdStart = out.length;
  for (final (i, f) in files.indexed) {
    u32(0x02014b50); // central directory entry
    for (final v in [3 << 8 | 20, 20, centralFlags, f.method, 0, 0]) {
      u16(v); // made by Unix, needed, flags, method, time, date
    }
    u32(0);
    u32(f.data.length);
    u32(f.size);
    for (final v in [f.name.length, 0, 0, 0, 0]) {
      u16(v); // name, extra and comment lengths, disk, internal attributes
    }
    u32(f.mode << 16); // external attributes
    u32(offsets[i]);
    out.add(ascii.encode(f.name));
  }
  final cdSize = out.length - cdStart;
  u32(0x06054b50); // end of central directory
  for (final v in [0, 0, files.length, files.length]) {
    u16(v);
  }
  u32(cdSize);
  u32(cdStart);
  u16(0);
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

  test('eager copies run a few at a time; a failed one is retried', () async {
    var broken = true;
    final client = CountingClient(
      (name, attempt) => name == 'never.bin'
          ? broken
          : name.startsWith('once-') && attempt == 1,
    );
    c = await Cluster.start(
      2,
      ttl: const Duration(seconds: 30),
      client: (i) => i == 1 ? client : null,
    );
    final [a, b] = c.nodes;
    // A burst, as from one drop of many screenshots. Half fail their first
    // copy, which the next poll must try again.
    await Future.wait([
      for (var i = 0; i < 40; i++)
        a.addBytes([i], i.isEven ? 'once-$i.bin' : 'fine-$i.bin'),
    ]);
    final never = await a.addBytes([1], 'never.bin');
    await eventually(
      () =>
          b.items.length == 41 && b.items.where((i) => i.isReady).length == 40,
      timeout: const Duration(seconds: 10),
      reason: 'not every eager copy landed',
    );
    expect(client.maxInFlight, greaterThan(1), reason: 'never overlapped');
    expect(client.maxInFlight, lessThanOrEqualTo(SyncEngine.maxEagerDownloads));
    for (var i = 0; i < 40; i++) {
      expect(
        client.calls[i.isEven ? 'once-$i.bin' : 'fine-$i.bin'],
        i.isEven ? 2 : 1,
      );
    }

    // One that keeps failing is left for a tap after its last try.
    await eventually(
      () => client.calls['never.bin'] == SyncEngine.maxEagerTries,
    );
    await Future<void>.delayed(const Duration(seconds: 1)); // three polls
    expect(client.calls['never.bin'], SyncEngine.maxEagerTries);
    final key = itemKey(a.id, never.id);
    expect(b.store[key]?.isReady, isFalse, reason: 'still listed');
    broken = false;
    await b.fetch(key);
    expect(b.store[key]!.isReady, isTrue);
  });

  test("a trickling sender cannot hold up another's text", () async {
    // Ten seconds each, listed largest first.
    final trickler = await Trickler.start({
      for (var i = 0; i < 6; i++) 'slow$i': 105 - i,
    });
    addTearDown(trickler.close);
    final client = CountingClient((_, _) => false);
    c = await Cluster.start(
      2,
      ttl: const Duration(seconds: 30),
      client: (i) => i == 1 ? client : null,
    );
    final [a, b] = c.nodes;
    c.discoveries[1].add(trickler.peer);
    await eventually(
      () => trickler.requests.length == SyncEngine.maxEagerPerPeer,
    );
    // Smallest first, and no more than its share.
    expect(trickler.requests.keys, unorderedEquals(['slow5', 'slow4']));
    expect(client.inFlightByPort[trickler.port], SyncEngine.maxEagerPerPeer);

    final text = await a.addText('one line from another phone');
    await eventually(
      () => b.store[text.key]?.isReady ?? false,
      timeout: const Duration(seconds: 2),
      reason: 'the text waited behind the trickle',
    );
    expect(client.maxInFlightByPort[trickler.port], SyncEngine.maxEagerPerPeer);
  });

  test('an eager copy runs out of time; a tap does not', () async {
    // A second a copy, past a deadline of 400 ms.
    final trickler = await Trickler.start({'slow': 10, 'joined': 10});
    addTearDown(trickler.close);
    c = await Cluster.start(
      1,
      ttl: const Duration(seconds: 30),
      eagerDeadline: const Duration(milliseconds: 400),
    );
    final [b] = c.nodes;
    c.discoveries[0].add(trickler.peer);

    // A tap on a copy already running keeps it going.
    await eventually(() => trickler.requests['joined'] == 1);
    await b.fetch(itemKey('trickler', 'joined'));
    expect(trickler.requests['joined'], 1);

    // Without one, the copy is dropped each time, and after its last try
    // the item waits for a tap like a large one.
    await eventually(
      () => trickler.requests['slow'] == SyncEngine.maxEagerTries,
      reason: 'a deadline missed did not count as a failed try',
    );
    await Future<void>.delayed(const Duration(seconds: 1)); // three polls
    expect(trickler.requests['slow'], SyncEngine.maxEagerTries);
    final slow = itemKey('trickler', 'slow');
    expect(b.store[slow]?.isReady, isFalse);
    expect(b.store[slow]?.progress, isNull);
    await b.fetch(slow);
    expect(b.store[slow]?.isReady, isTrue);
  });

  // The app waits this long for an arrival it means to copy, and no longer.
  test("an eager copy's deadline grows a second per 256 KB", () async {
    c = await Cluster.start(1, eagerDeadline: const Duration(seconds: 30));
    final e = c.nodes.single.engine;
    expect(e.eagerDeadlineFor(0), const Duration(seconds: 30));
    expect(e.eagerDeadlineFor(256 << 10), const Duration(seconds: 31));
    expect(e.eagerDeadlineFor(25 << 20), const Duration(seconds: 130));
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
    final same = await tempFile(c.root, 'same.txt', 100);
    final kept = await tempFile(c.root, 'kept.txt', 100);
    for (final f in [gone, grown, same, kept]) {
      await a.addFile(f.path);
    }
    await eventually(
      () => b.items.length == 4 && b.items.every((i) => i.isReady),
    );

    gone.deleteSync();
    grown.writeAsBytesSync([1, 2, 3], mode: FileMode.append);
    // Rewritten to the same size: only the modification time gives it
    // away. Set explicitly, since a file system's clock can be coarse.
    same.writeAsBytesSync(List.filled(100, 0));
    same.setLastModifiedSync(
      same.lastModifiedSync().add(const Duration(seconds: 2)),
    );
    await eventually(
      () => a.items.length == 1 && b.items.length == 1,
      reason: 'stale items still listed',
    );
    expect(a.items.single.name, 'kept.txt');
    expect(b.items.single.name, 'kept.txt');
  });

  test('a stat that hangs neither holds up the list nor piles up', () async {
    c = await Cluster.start(
      2,
      ttl: const Duration(seconds: 30),
      eagerCopyBytes: 1024,
    );
    final [a, b] = c.nodes;
    // Too big for an eager copy, so only the list ever stats it.
    final slow = await tempFile(c.root, 'on-a-dead-share.bin', 5000);
    await a.addFile(slow.path);
    final stat = HangingStat(slow.path);
    IOOverrides.global = stat;
    addTearDown(() {
      IOOverrides.global = null;
      if (!stat.release.isCompleted) stat.release.complete();
    });
    await a.addFile((await tempFile(c.root, 'fine.txt', 100)).path);

    await eventually(
      () => b.items.length == 2 && b.items.any((i) => i.isReady),
      reason: 'the list waited on the stat',
    );
    await Future<void>.delayed(const Duration(seconds: 1)); // three polls
    expect(b.peers.map((p) => p.id), [a.id], reason: 'A counted as gone');
    expect(stat.hung, 1, reason: 'every poll started a stat of its own');
    expect(a.items, hasLength(2));

    // The stat comes back at last, with the file gone: it still leaves.
    slow.deleteSync();
    stat.release.complete();
    await eventually(() => a.items.length == 1 && b.items.length == 1);
    expect(b.items.single.name, 'fine.txt');
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

  test('safeFileName fixes what Windows cannot store', () async {
    c = await Cluster.start(1);
    // Device names, with any extension, in any case: the stem gets a `_`.
    expect(safeFileName('CON'), 'CON_');
    expect(safeFileName('con.txt'), 'con_.txt');
    expect(safeFileName('Nul.tar.gz'), 'Nul_.tar.gz');
    expect(safeFileName('COM1'), 'COM1_');
    expect(safeFileName('lpt9.log'), 'lpt9_.log');
    expect(safeFileName('aux.'), 'aux_', reason: 'bare once the dot goes');
    // Near misses are left alone.
    for (final fine in ['console.txt', 'com10', 'config', 'nul-1', 'CONTENT']) {
      expect(safeFileName(fine), fine);
    }
    // Trailing dots and spaces are dropped there, so drop them everywhere,
    // or the name a Windows receiver shows differs from everyone else's.
    expect(safeFileName('notes.'), 'notes');
    expect(safeFileName('notes . . '), 'notes');
    expect(safeFileName('report.pdf. '), 'report.pdf');
    expect(safeFileName('.env'), '.env', reason: 'leading dots are fine');
  });

  test('a name cannot turn its extension around unseen', () async {
    c = await Cluster.start(1);
    // U+202E, right-to-left override: "a" then "exe.pdf" on screen.
    expect(safeFileName('a\u202Efdp.exe'), 'a_fdp.exe');
    // An isolate and its end, U+2067 and U+2069.
    expect(safeFileName('a\u2067fdp\u2069.exe'), 'a_fdp_.exe');
    // Marks that cannot turn Latin text around go without a trace, so
    // Hebrew with a right-to-left mark (U+200F), Arabic with its letter
    // mark (U+061C) and Thai with a zero-width space (U+200B) stay clean.
    expect(safeLabel('\u200Ba\uFEFF'), 'a');
    // Word joiner and the invisible operators, U+2060-2064, likewise.
    expect(safeLabel('a\u2060b\u2061c\u2062d\u2063e\u2064f'), 'abcdef');
    const report = '\u05D3\u05D5\u05D7 2024'; // Hebrew
    expect(safeFileName('$report\u200F.pdf'), '$report.pdf');
    const file = '\u0645\u0644\u0641'; // Arabic
    expect(safeLabel('$file\u061C.txt'), '$file.txt');
    const hello = '\u0E2A\u0E27\u0E31\u0E2A\u0E14\u0E35'; // Thai, two words
    const sir = '\u0E04\u0E23\u0E31\u0E1A';
    expect(safeFileName('$hello\u200B$sir.docx'), '$hello$sir.docx');
    // The joiner in an emoji sequence, or in Persian, is left alone.
    const family = '\u{1F468}\u200D\u{1F469}.png';
    expect(safeFileName(family), family);
    const iWant = '\u0645\u06CC\u200C\u062E\u0648\u0627\u0647\u0645';
    expect(safeLabel(iWant), iWant);

    // A line break, C0 or C1, cuts a one-line row short, and so do the
    // line and paragraph separators, U+2028 and U+2029.
    expect(safeLabel('invoice.pdf\n.exe'), 'invoice.pdf_.exe');
    expect(safeLabel('invoice.pdf .exe'), 'invoice.pdf_.exe');
    expect(safeFileName('invoice.pdf .exe'), 'invoice.pdf_.exe');
    expect(safeLabel('a\r\tb\x7f\x85c'), 'a__b__c');
    expect(safeFileName('invoice.pdf\n.exe'), 'invoice.pdf_.exe');

    // The row shows what saving it would write.
    final s = c.nodes.single.store;
    ShelfItem mirror(String name) => s.addRemote(
      'p',
      'p',
      RemoteItem(
        id: randomId(),
        name: name,
        size: 1,
        mime: 'application/pdf',
        kind: ItemKind.file,
        ttlMs: 1000,
      ),
    )!;
    expect(mirror('invoice\u202Efdp.exe').name, 'invoice_fdp.exe');
    expect(mirror('invoice.pdf\n.exe').name, 'invoice.pdf_.exe');

    // A Windows text's first line does not carry its `\r` to the label.
    expect((await s.addText('hello\r\nworld')).name, 'hello');
  });

  test('a cut never splits a character', () async {
    c = await Cluster.start(1);
    final s = c.nodes.single.store;
    const grin = '\u{1F600}'; // two UTF-16 units
    const flag = '\u{1F1FA}\u{1F1F8}'; // two regional indicators, four units
    // A family: three people and two joiners, eight units.
    const family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}';
    Future<String> label(String text) async => (await s.addText(text)).name;
    // Each straddles the 60th unit, or ends on it.
    expect(await label('${'a' * 59}$grin and more'), '${'a' * 59}…');
    expect(await label('${'a' * 58}$grin and more'), '${'a' * 58}$grin…');
    expect(await label('${'a' * 58}$flag and more'), '${'a' * 58}…');
    expect(await label('${'a' * 56}$flag and more'), '${'a' * 56}$flag…');
    expect(await label('${'a' * 55}$family and more'), '${'a' * 55}…');
    expect(await label('${'a' * 52}$family and more'), '${'a' * 52}$family…');

    String mirrorName(String name) => s
        .addRemote(
          'p',
          'p',
          RemoteItem(
            id: randomId(),
            name: name,
            size: 1,
            mime: 'image/png',
            kind: ItemKind.file,
            ttlMs: 1000,
          ),
        )!
        .name;
    const max = ShelfStore.maxNameLength;
    expect(mirrorName('${'n' * (max - 1)}$grin.png'), 'n' * (max - 1));
    expect(mirrorName('${'n' * (max - 2)}$flag.png'), 'n' * (max - 2));
    expect(mirrorName('${'n' * (max - 4)}$family.png'), 'n' * (max - 4));

    // safeFileName keeps the last 120 units, the extension's end.
    expect(safeFileName('x$grin${'a' * 119}'), 'a' * 119);
    expect(safeFileName('x$grin${'a' * 118}'), '$grin${'a' * 118}');
    expect(safeFileName('x$flag${'a' * 117}'), 'a' * 117);
    expect(safeFileName('x$flag${'a' * 116}'), '$flag${'a' * 116}');
    expect(safeFileName('x$family${'a' * 115}'), 'a' * 115);
    expect(safeFileName('x$family${'a' * 112}'), '$family${'a' * 112}');
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

  test('a transfer keeps its row while its sender drops out', () async {
    final gate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    c = await Cluster.start(
      2,
      ttl: const Duration(seconds: 30),
      eagerCopyBytes: 1024,
      client: (i) => i == 1 ? GatedClient(gate.future) : null,
    );
    final [a, b] = c.nodes;
    final saved = await a.addBytes(List.filled(5000, 4), 'saved.bin');
    final fetched = await a.addBytes(List.filled(5000, 5), 'fetched.bin');
    await eventually(() => b.items.length == 2);
    final dest = '${c.root.path}/saved.bin';
    final save = b.saveTo(saved.key, dest);
    // Listened to now: it fails while the save is still being awaited.
    final fetch = expectLater(
      b.fetch(fetched.key),
      throwsA(isA<HttpException>()),
    );
    await eventually(() => b.items.every((i) => i.progress != null));

    // A's mDNS record goes mid-transfer: a flicker, or iOS re-registering.
    c.discoveries[1].remove(a.id);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(b.store[saved.key]?.progress, isNotNull, reason: 'save dropped');
    expect(b.store[fetched.key]?.progress, isNotNull, reason: 'fetch dropped');

    // The save lands; the fetch fails, its item gone from A meanwhile.
    a.remove(fetched.key);
    gate.complete();
    await save;
    expect(File(dest).lengthSync(), 5000);
    await fetch;
    // The sender is still gone, so neither row lingers.
    expect(b.items, isEmpty);
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

  test('a download is dropped when its cut-off comes', () async {
    c = await Cluster.start(1);
    final trickler = await Trickler.start({'x': 100});
    addTearDown(trickler.close);
    final client = NodeClient();
    addTearDown(client.close);
    final dest = '${c.root.path}/x.bin';
    final clock = Stopwatch()..start();
    await expectLater(
      client.download(
        Uri.parse('http://127.0.0.1:${trickler.port}'),
        'x',
        dest,
        expectedSize: 100,
        cutOff: Future.delayed(const Duration(milliseconds: 300)),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
    expect(File('$dest.part').existsSync(), isFalse);
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

  test('a refusal with an endless body is hung up on, not read', () async {
    c = await Cluster.start(1);
    final liar = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => liar.close(force: true));
    liar.listen((req) async {
      final res = req.response..statusCode = HttpStatus.serviceUnavailable;
      final pad = List.filled(64 * 1024, 0x20);
      final until = DateTime.now().add(const Duration(seconds: 5));
      // Paced by a timer, not by the socket: dart:io hides a hang-up from
      // the server, so once the client is gone every flush completes at
      // once, and a loop on them alone would starve the isolate, client
      // included. The bound only ends the test if the client fails to
      // hang up; a drain would read until then, or time out.
      while (DateTime.now().isBefore(until)) {
        res.add(pad);
        await res.flush();
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      res.close().ignore();
    });
    final base = Uri.parse('http://127.0.0.1:${liar.port}');
    final client = NodeClient();
    addTearDown(client.close);
    final clock = Stopwatch()..start();
    await expectLater(
      client.fetchList(base, 'me'),
      throwsA(isA<HttpException>()),
    );
    await expectLater(
      client.download(base, 'x', '${c.root.path}/x.bin', expectedSize: 1),
      throwsA(isA<HttpException>()),
    );
    expect(
      clock.elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'should hang up on the body, not wait for it',
    );
    expect(File('${c.root.path}/x.bin.part').existsSync(), isFalse);
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

  test('a mirror that drops out and comes back keeps its place', () async {
    c = await Cluster.start(
      2,
      ttl: const Duration(seconds: 30),
      eagerCopyBytes: 1024,
    );
    final [a, b] = c.nodes;
    // Too big for an eager copy, so losing the peer drops it.
    final big = await a.addBytes(List.filled(5000, 1), 'big.bin');
    await eventually(() => b.store[big.key] != null);
    final firstSeen = b.store[big.key]!.addedAt;
    final mine = await b.addText('mine, later');
    expect(b.items.map((i) => i.id), [mine.id, big.id]);

    // A's mDNS record flickers: gone, then back a moment later.
    c.discoveries[1].remove(a.id);
    await eventually(() => b.store[big.key] == null);
    c.connect(1, 0);
    await eventually(() => b.store[big.key] != null);
    expect(b.items.map((i) => i.id), [
      mine.id,
      big.id,
    ], reason: 'came back as the newest');
    expect(b.store[big.key]!.addedAt, firstSeen);
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

  test(
    'names that sanitise alike inside a folder are numbered apart',
    () async {
      c = await Cluster.start(1);
      final alike = Archive()
        ..add(stored('a:b.txt', [1]))
        ..add(stored('a?b.txt', [2]))
        ..add(stored('notes:', [3]))
        ..add(
          ArchiveFile.directory('notes_')..compression = CompressionType.none,
        )
        ..add(stored('notes_/x.txt', [4]))
        // One entry named twice, which a zip allows. The Archive class
        // merges identical names, so the second is spelt with a `.`
        // segment, which the unpacker drops.
        ..add(stored('notes_/.env', [5]))
        ..add(stored('notes_/./.env', [6]));
      final zip = File('${c.root.path}/alike.zip')
        ..writeAsBytesSync(ZipEncoder().encode(alike));
      final out = '${c.root.path}/out';
      await extractFolder(zip.path, out);
      expect(File('$out/a_b.txt').readAsBytesSync(), [1]);
      expect(File('$out/a_b (1).txt').readAsBytesSync(), [2]);
      // A file and a folder cannot share a name either, and the folder's
      // contents follow it wherever it lands.
      expect(File('$out/notes_').readAsBytesSync(), [3]);
      expect(File('$out/notes_ (1)/x.txt').readAsBytesSync(), [4]);
      // The second of the twice-named entries does not overwrite the first.
      expect(File('$out/notes_ (1)/.env').readAsBytesSync(), [5]);
      expect(File('$out/notes_ (1)/.env (1)').readAsBytesSync(), [6]);
    },
  );

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
    // Nor is a file that happens to be at the target path: creating the
    // folder fails, and "no folder there" must never be read as "nothing
    // there", since the cleanup deletes whatever is at the path.
    final taken = File('${c.root.path}/taken')..writeAsStringSync('keep');
    await expectLater(
      extractFolder(zip.path, taken.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(taken.existsSync(), isTrue, reason: 'file at the target deleted');
    expect(taken.readAsStringSync(), 'keep');
  });

  test('a deflated entry posing as a link is refused unread', () async {
    c = await Cluster.start(1);
    // ZipDecoder reads a link's target while decoding, before any check of
    // plop's could run, so a deflated one was inflated into memory whole.
    // These bytes are no deflate stream (the first block is of the reserved
    // type), so a version that tried to inflate them before refusing would
    // fail some other way: "compressed" means they were never read.
    final garbage = List.filled(1024, 0xff);
    expect(
      () => ZLibCodec(raw: true).decode(garbage),
      throwsA(isA<FormatException>()),
    );
    final readme = (
      name: 'readme.txt',
      data: [1],
      method: 0,
      size: 1,
      mode: 0x81a4, // a file, 0644
    );
    final zip = File('${c.root.path}/link.zip')
      ..writeAsBytesSync(
        handZip([
          readme,
          (
            name: 'link',
            data: garbage,
            method: 8, // deflate
            size: 1 << 20, // as claimed
            mode: 0xa1ff, // a symlink, 0777
          ),
        ]),
      );
    expect(zip.lengthSync(), lessThan(8 * 1024), reason: 'not a bomb');
    Matcher refused(String why) => throwsA(
      isA<FormatException>().having((e) => e.message, 'message', contains(why)),
    );
    final out = Directory('${c.root.path}/x/out');
    await expectLater(extractFolder(zip.path, out.path), refused('compressed'));
    expect(out.existsSync(), isFalse);

    // A method the archive package does not know reads as stored in the
    // local header; the central directory still gives it away.
    final odd = File('${c.root.path}/odd.zip')
      ..writeAsBytesSync(
        handZip([
          readme,
          (
            name: 'lzma.bin',
            data: garbage,
            method: 14,
            size: 1 << 20,
            mode: 0x81a4,
          ),
        ]),
      );
    await expectLater(extractFolder(odd.path, out.path), refused('compressed'));
    expect(out.existsSync(), isFalse);

    // The same zip with the link stored unpacks, leaving the link out.
    final tame = File('${c.root.path}/tame.zip')
      ..writeAsBytesSync(
        handZip([
          readme,
          (
            name: 'link',
            data: ascii.encode('..'),
            method: 0,
            size: 2,
            mode: 0xa1ff,
          ),
        ]),
      );
    await extractFolder(tame.path, out.path);
    expect(
      out.listSync().map((e) => e.path.split(Platform.pathSeparator).last),
      ['readme.txt'],
    );
  });

  test('a folder zip with an encrypted entry is refused', () async {
    c = await Cluster.start(1);
    final entry = (
      name: 'secret.bin',
      data: List.filled(64, 7),
      method: 0,
      size: 64,
      mode: 0x81a4,
    );
    final out = Directory('${c.root.path}/out');
    // Flagged in the local header only, then in the central one only.
    for (final (local, central) in [(1, 0), (0, 1)]) {
      final zip = File('${c.root.path}/locked$local$central.zip')
        ..writeAsBytesSync(
          handZip([entry], localFlags: local, centralFlags: central),
        );
      await expectLater(
        extractFolder(zip.path, out.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('encrypted'),
          ),
        ),
      );
      expect(out.existsSync(), isFalse);
    }
    // Unflagged, the same entry unpacks.
    final plain = File('${c.root.path}/plain.zip')
      ..writeAsBytesSync(handZip([entry]));
    await extractFolder(plain.path, out.path);
    expect(File('${out.path}/secret.bin').readAsBytesSync(), entry.data);
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

  test('caller ids not plain tokens are ignored; the rest capped', () async {
    c = await Cluster.start(1, ttl: const Duration(seconds: 30));
    final [a] = c.nodes;
    final item = await a.addText('x');
    final http = HttpClient();
    addTearDown(() => http.close(force: true));
    Future<void> call(String method, String path, String from) async {
      final req = await http.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${a.port}$path'),
      );
      req.headers.set(nodeIdHeader, from);
      await (await req.close()).drain<void>();
    }

    // Each distinct value would otherwise be one more entry for good.
    for (final bad in ['../../x', 'a b', 'x' * 65, '<script>']) {
      await call('GET', '/v1/items', bad);
      await call('POST', '/v1/items/${item.id}/received', bad);
      await call('POST', '/v1/changed', bad);
    }
    expect(a.server.seenBy, isEmpty);
    expect(item.receivedBy, isEmpty);
    expect(isValidId('../../x'), isFalse);

    const odd = 'odd-but_OK';
    expect(isValidId(odd), isTrue);
    await call('GET', '/v1/items', odd);
    await call('POST', '/v1/items/${item.id}/received', odd);
    expect(a.server.seenBy.keys, [odd]);
    expect(item.receivedBy, {odd});

    // A plain token can still be made up afresh for every request.
    for (var i = 0; i < NodeServer.maxSeenBy + 50; i++) {
      await call('GET', '/v1/items', 'made-up-$i');
      if (i < ShelfStore.maxReceivedBy) {
        await call('POST', '/v1/items/${item.id}/received', 'made-up-$i');
      }
    }
    expect(a.server.seenBy, hasLength(NodeServer.maxSeenBy));
    expect(a.server.seenBy, isNot(contains(odd)), reason: 'oldest kept');
    expect(item.receivedBy, hasLength(ShelfStore.maxReceivedBy));
    // The least recently heard from goes first, so a peer that keeps
    // polling stays however many others come and go.
    final first = a.server.seenBy.keys.first;
    await call('GET', '/v1/items', first);
    await call('GET', '/v1/items', 'real');
    expect(a.server.seenBy.keys.skip(NodeServer.maxSeenBy - 2), [
      first,
      'real',
    ]);
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

  test('a peer that reaches us but cannot be reached is flagged', () async {
    c = await Cluster.start(2, ttl: const Duration(seconds: 30));
    final [a, b] = c.nodes;
    await eventually(() => a.peers.isNotEmpty && b.peers.isNotEmpty);
    expect(a.unreachable, isEmpty);

    // B's firewall turns away whatever comes in; B still polls A.
    await b.server.stop();
    // Out of [peers] at the first missed poll, flagged at the third.
    await eventually(() => a.unreachable.isNotEmpty);
    expect(a.unreachable.map((p) => p.id), [b.id]);
    expect(a.peers, isEmpty);
    expect(b.peers.map((p) => p.id), [a.id]);
    expect(b.unreachable, isEmpty);

    // Once B no longer reaches A either, discovery listing it is not
    // enough: it may have left without a goodbye.
    c.discoveries[1].remove(a.id);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    a.server.seenBy[b.id] = DateTime.now().subtract(PlopNode.oneWayAfter * 2);
    expect(a.engine.unreachablePeers.map((p) => p.id), [b.id]);
    expect(a.unreachable, isEmpty);
  });

  test('a peer that goes quiet is never taken for a blocked one', () async {
    c = await Cluster.start(2, ttl: const Duration(seconds: 30));
    final [a, b] = c.nodes;
    await eventually(() => a.peers.isNotEmpty && b.peers.isNotEmpty);
    // B's phone locks: it stops polling A and stops answering at once.
    c.discoveries[1].remove(a.id);
    await b.server.stop();
    var flagged = false;
    final clock = Stopwatch()..start();
    // Past A's third failed poll, well inside the 12 s of its last contact.
    while (clock.elapsed < const Duration(seconds: 3)) {
      flagged |= a.unreachable.isNotEmpty;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(a.engine.unreachablePeers.map((p) => p.id), [b.id]);
    expect(flagged, isFalse);
  });

  test('the server answers over IPv6 too where the host has it', () async {
    c = await Cluster.start(1, ttl: const Duration(seconds: 30));
    final [a] = c.nodes;
    Future<int> status(InternetAddress host) async {
      final res = await HttpClient()
          .getUrl(
            Uri(
              scheme: 'http',
              host: host.address,
              port: a.port,
              path: '/v1/items',
            ),
          )
          .then((r) => r.close());
      await res.drain<void>();
      return res.statusCode;
    }

    expect(await status(InternetAddress.loopbackIPv4), 200);
    // Only where ::1 can be bound at all, so a v4-only runner still passes.
    try {
      await (await ServerSocket.bind(InternetAddress.loopbackIPv6, 0)).close();
    } on SocketException {
      return;
    }
    expect(await status(InternetAddress.loopbackIPv6), 200);
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
