import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:plop_core/plop_core.dart';
import 'package:test/test.dart';

/// Two nodes on loopback that know each other. The web shelf is tested on
/// [a]; [b] is the peer whose items it mirrors and that mirrors its uploads.
class Pair {
  Pair._(this.a, this.b, this.root, this.da);

  final PlopNode a, b;
  final Directory root;

  /// [a]'s peer list, for adding a [fakePeer] to.
  final StaticDiscovery da;

  static Future<Pair> start({
    int eagerCopyBytes = defaultEagerCopyBytes,
    int maxItemBytes = defaultMaxItemBytes,
    Duration ttl = const Duration(seconds: 30),
  }) async {
    final root = await Directory.systemTemp.createTemp('plop_web');
    final da = StaticDiscovery(), db = StaticDiscovery();
    Future<PlopNode> node(String name, PeerDiscovery d) => PlopNode.start(
      dir: Directory('${root.path}/$name'),
      discovery: d,
      name: name,
      ttl: ttl,
      eagerCopyBytes: eagerCopyBytes,
      maxItemBytes: maxItemBytes,
      pollInterval: const Duration(milliseconds: 300),
    );
    final a = await node('mac', da), b = await node('phone', db);
    da.add(Peer(id: b.id, name: 'phone', hosts: ['127.0.0.1'], port: b.port));
    db.add(Peer(id: a.id, name: 'mac', hosts: ['127.0.0.1'], port: a.port));
    a.web.enabled = true;
    return _running = Pair._(a, b, root, da);
  }

  Uri url(String path) => Uri.parse('http://127.0.0.1:${a.port}$path');

  Future<void> stop() async {
    await a.stop();
    await b.stop();
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

typedef Reply = ({int status, HttpHeaders headers, Uint8List body});

final http = HttpClient();

Future<Reply> send(
  String method,
  Uri uri, {
  List<int>? body,
  bool chunked = false,
}) async {
  final req = await http.openUrl(method, uri);
  if (body != null) {
    if (chunked) {
      req.headers.chunkedTransferEncoding = true;
      for (var i = 0; i < body.length; i += 64 * 1024) {
        req.add(body.sublist(i, (i + 64 * 1024).clamp(0, body.length)));
      }
    } else {
      req.contentLength = body.length;
      req.add(body);
    }
  }
  final res = await req.close();
  final buf = BytesBuilder(copy: false);
  await for (final chunk in res) {
    buf.add(chunk);
  }
  return (status: res.statusCode, headers: res.headers, body: buf.takeBytes());
}

Future<Reply> get(Uri uri) => send('GET', uri);

List<dynamic> shelfOf(Reply r) => jsonDecode(utf8.decode(r.body)) as List;

/// A request written straight to the socket, answered with its status
/// line. For bodies the server is expected to refuse before it has read
/// them to the end: dart's HttpClient has no way to stop sending, and a
/// client still writing when the server hangs up can lose the answer.
Future<String> rawStatus(int port, String head, [List<int>? body]) async {
  final s = await Socket.connect('127.0.0.1', port);
  s.done.ignore(); // the server hangs up with our bytes unread
  s.add(utf8.encode(head));
  if (body != null) s.add(body);
  final line = await utf8.decoder.bind(s).transform(const LineSplitter()).first;
  s.destroy();
  return line;
}

/// A whole response as raw text, head and body, for checking what went
/// over the wire rather than what dart:io makes of it.
Future<String> rawResponse(int port, String head) async {
  final s = await Socket.connect('127.0.0.1', port);
  s.add(utf8.encode(head));
  final out = await utf8.decoder.bind(s).join();
  s.destroy();
  return out;
}

/// A peer that lists [items] and serves [bytes] by id, saying whatever a
/// hostile one might.
Future<HttpServer> fakePeer(
  List<Map<String, Object>> items,
  Map<String, List<int>> bytes,
) async {
  final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((req) async {
    final res = req.response;
    switch (req.uri.pathSegments) {
      case ['v1', 'items']:
        res.write(jsonEncode(items));
      case ['v1', 'items', final id] when bytes.containsKey(id):
        res.contentLength = bytes[id]!.length;
        res.add(bytes[id]!);
      default:
        res.statusCode = 404;
    }
    await res.close();
  });
  return s;
}

List<int> chunkedBody(int total, int chunk) {
  final out = BytesBuilder();
  for (var n = 0; n < total; n += chunk) {
    final len = (total - n).clamp(0, chunk);
    out
      ..add(ascii.encode('${len.toRadixString(16)}\r\n'))
      ..add(List.filled(len, 7))
      ..add(ascii.encode('\r\n'));
  }
  return out.takeBytes();
}

/// The pair the current test started, if it started one.
Pair? _running;

void main() {
  late Pair p;
  tearDown(() async {
    await _running?.stop();
    _running = null;
  });
  tearDownAll(() => http.close(force: true));

  test('disabled, the web routes answer 404 and /v1 is untouched', () async {
    p = await Pair.start();
    p.a.web.enabled = false;
    for (final path in ['/', '/web/shelf', '/manifest.webmanifest']) {
      expect((await get(p.url(path))).status, 404, reason: path);
    }
    expect((await get(p.url('/v1/items'))).status, 200);
  });

  test('only a LAN host name is answered, on every route', () async {
    p = await Pair.start();
    final port = p.a.port;
    Future<String> as(String host, String path) => rawStatus(
      port,
      'GET $path HTTP/1.1\r\nHost: $host\r\nConnection: close\r\n\r\n',
    );
    // A page out on the web that pointed its own name at this machine.
    for (final host in [
      'attacker.example',
      'attacker.example:$port',
      'evil.com.:$port',
      '127.0.0.1.evil.com',
      'localhost.evil.com',
      'local',
      '[::1',
      '[nope]:$port',
      '127.0.0.1:x',
      '',
    ]) {
      for (final path in ['/', '/web/shelf', '/v1/items']) {
        expect(await as(host, path), contains('421'), reason: '$host $path');
      }
    }
    // Two Host headers, one of them fine.
    expect(
      await rawStatus(
        port,
        'GET /web/shelf HTTP/1.1\r\nHost: 127.0.0.1\r\n'
        'Host: attacker.example\r\nConnection: close\r\n\r\n',
      ),
      anyOf(contains('421'), contains('400')),
    );
    // Refused before a byte of an upload is read.
    expect(
      await rawStatus(
        port,
        'POST /web/text HTTP/1.1\r\nHost: attacker.example\r\n'
        'Content-Length: 1000000\r\n\r\n',
      ),
      contains('421'),
    );
    expect(p.a.items, isEmpty);

    for (final host in [
      '127.0.0.1',
      '127.0.0.1:$port',
      '192.168.1.20:$port',
      '[::1]:$port',
      '[fe80::1%25en0]:$port',
      'localhost:$port',
      'plop.localhost',
      'zains-macbook.local:$port',
      'Zains-MacBook.local.',
    ]) {
      expect(await as(host, '/web/shelf'), contains('200'), reason: host);
      expect(await as(host, '/v1/items'), contains('200'), reason: host);
    }
  });

  test('isLanHost', () {
    expect(isLanHost(null), isTrue, reason: 'no browser leaves it out');
    expect(isLanHost('10.0.0.5:7567'), isTrue);
    expect(isLanHost('[2001:db8::1]:7567'), isTrue);
    expect(isLanHost('[2001:db8::1]'), isTrue);
    expect(isLanHost('2001:db8::1'), isFalse, reason: 'brackets required');
    expect(isLanHost('[10.0.0.5]'), isFalse);
    expect(isLanHost('[::1]x'), isFalse);
    expect(isLanHost('localhost'), isTrue);
    expect(isLanHost('a.b.localhost:1'), isTrue);
    expect(isLanHost('mac.local'), isTrue);
    expect(isLanHost('mac.lan'), isFalse);
    expect(isLanHost('example.com'), isFalse);
    expect(isLanHost('1.2.3.4.nip.io'), isFalse);
    expect(isLanHost('mac.local:123456'), isFalse);
  });

  test('the page, the manifest and the icon are served', () async {
    p = await Pair.start();
    final page = await get(p.url('/'));
    expect(page.status, 200);
    expect(page.headers.contentType?.mimeType, 'text/html');
    expect(page.headers.value('cache-control'), contains('max-age'));
    final html = utf8.decode(page.body);
    expect(html, contains('<title>plop · mac</title>'));
    expect(html, contains('rel="manifest"'));
    expect(html, contains('apple-mobile-web-app-capable'));
    expect(html, isNot(contains('{{name}}')));
    // Nothing is fetched from outside the LAN.
    expect(html, isNot(contains('https://')));
    final head = await send('HEAD', p.url('/'));
    expect(head.status, 200);
    expect(head.headers.contentType?.mimeType, 'text/html');
    expect(head.body, isEmpty);

    final manifest = await get(p.url('/manifest.webmanifest'));
    expect(manifest.headers.contentType?.mimeType, 'application/manifest+json');
    final m = jsonDecode(utf8.decode(manifest.body)) as Map;
    expect(m['name'], 'plop');
    expect(m['display'], 'standalone');
    expect(m['start_url'], '/');
    expect(m['background_color'], '#0A0A0A');
    expect((m['icons'] as List).first['src'], '/icon.png');

    // A black pixel until the app hands over its icon.
    final icon = await get(p.url('/icon.png'));
    expect(icon.headers.contentType?.mimeType, 'image/png');
    expect(icon.body.sublist(0, 4), [0x89, 0x50, 0x4e, 0x47]);
    p.a.web.iconPng = Uint8List.fromList([1, 2, 3]);
    expect((await get(p.url('/icon.png'))).body, [1, 2, 3]);
  });

  test('the shelf lists own and mirrored items, newest first', () async {
    p = await Pair.start();
    final pic = await p.b.addBytes(List.filled(300, 9), 'pic.png');
    await eventually(() => p.a.store[pic.key]?.isReady ?? false);
    final note = await p.a.addText('hello\nfrom the mac');

    final r = await get(p.url('/web/shelf'));
    expect(r.status, 200);
    expect(r.headers.contentType?.mimeType, 'application/json');
    expect(r.headers.value('cache-control'), 'no-store');
    final list = shelfOf(r);
    expect(list.length, 2);
    expect(list[0]['key'], note.key, reason: 'newest first');
    expect(list[0]['from'], 'mac');
    expect(list[0]['kind'], 'text');
    expect(list[0]['name'], 'hello');
    expect(list[0]['text'], 'hello\nfrom the mac', reason: 'small text inline');
    expect(list[0]['receivedBy'], 0);
    expect(list[1]['key'], pic.key);
    expect(list[1]['from'], 'phone');
    expect(list[1]['size'], 300);
    expect(list[1]['mime'], 'image/png');
    expect(list[1]['ready'], isTrue);
    expect(list[1]['ttlMs'], inInclusiveRange(1, 30000));
    expect(list[1].containsKey('receivedBy'), isFalse, reason: 'not own');
    expect(list[1].containsKey('text'), isFalse);
  });

  test('a peer cannot write headers through its mime', () async {
    p = await Pair.start();
    const evil =
        'text/html\r\nContent-Length: 45\r\n\r\n<script>alert(1)</script>';
    final html = utf8.encode('<script>alert(document.domain)</script>');
    final peer = await fakePeer(
      [
        {
          'id': 'evil1',
          'name': 'evil.html',
          'size': html.length,
          'mime': evil,
          'kind': 'file',
          'ttlMs': 30000,
        },
        {
          'id': 'ok1',
          'name': 'notes.txt',
          'size': 2,
          'mime': 'Text/Plain; Charset=UTF-8; x=y',
          'kind': 'file',
          'ttlMs': 30000,
        },
      ],
      {'evil1': html, 'ok1': utf8.encode('hi')},
    );
    addTearDown(() => peer.close(force: true));
    p.da.add(
      Peer(id: 'peer0', name: 'evil', hosts: ['127.0.0.1'], port: peer.port),
    );
    await eventually(() => p.a.store['peer0/evil1']?.isReady ?? false);
    expect(p.a.store['peer0/evil1']!.mime, 'application/octet-stream');
    expect(p.a.store['peer0/ok1']!.mime, 'text/plain; charset=utf-8');

    final raw = await rawResponse(
      p.a.port,
      'GET /web/items/peer0/evil1 HTTP/1.1\r\nHost: 127.0.0.1\r\n'
      'Connection: close\r\n\r\n',
    );
    final head = raw.substring(0, raw.indexOf('\r\n\r\n')).toLowerCase();
    expect(head, startsWith('http/1.1 200'));
    expect(head, contains('content-type: application/octet-stream'));
    expect(head, contains('content-security-policy: sandbox'));
    expect(head, isNot(contains('text/html')));
    expect('content-length:'.allMatches(head).length, 1);
    expect(raw.substring(raw.indexOf('\r\n\r\n') + 4), utf8.decode(html));
  });

  test('downloading a mirror not copied yet fetches it first', () async {
    p = await Pair.start(eagerCopyBytes: 1024);
    final bytes = List.generate(50 * 1024, (i) => i % 251);
    final big = await p.b.addBytes(bytes, 'Zürich 🏔.bin');
    await eventually(() => p.a.store[big.key] != null);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(p.a.store[big.key]!.isReady, isFalse, reason: 'over the eager cap');

    final r = await get(p.url('/web/items/${big.key}'));
    expect(r.status, 200);
    expect(r.body, bytes);
    expect(r.headers.contentType?.mimeType, 'application/octet-stream');
    expect(r.headers.contentLength, bytes.length);
    expect(
      r.headers.value('content-disposition'),
      'attachment; filename="Z_rich _.bin"; '
      "filename*=UTF-8''Z%C3%BCrich%20%F0%9F%8F%94.bin",
    );
    expect(p.a.store[big.key]!.isReady, isTrue, reason: 'kept as a mirror');

    // A folder comes as its zip; text as text.
    final dir = Directory('${p.root.path}/Design notes')..createSync();
    File('${dir.path}/a.txt').writeAsStringSync('a');
    final folder = await p.b.addPath(dir.path);
    await eventually(() => p.a.store[folder.key]?.isReady ?? false);
    final z = await get(p.url('/web/items/${folder.key}'));
    expect(z.headers.contentType?.mimeType, 'application/zip');
    expect(z.headers.value('content-security-policy'), 'sandbox');
    expect(
      z.headers.value('content-disposition'),
      contains('Design%20notes.zip'),
    );
    expect(z.body.sublist(0, 2), [0x50, 0x4b]);
    final note = await p.a.addText('hi');
    final t = await get(p.url('/web/items/${note.key}'));
    expect(t.headers.contentType?.mimeType, 'text/plain');
    expect(utf8.decode(t.body), 'hi');
  });

  test('a 3 MB upload streams onto the shelf and over to the peer', () async {
    p = await Pair.start();
    final bytes = List.generate(3 * 1024 * 1024, (i) => i * 7 % 253);
    final r = await send(
      'POST',
      p.url('/web/items?name=${Uri.encodeQueryComponent('IMG 0001.heic')}'),
      body: bytes,
    );
    expect(r.status, 200);
    final key = (jsonDecode(utf8.decode(r.body)) as Map)['key'] as String;
    final item = p.a.store[key]!;
    expect(item.originId, p.a.id, reason: "the host's own item");
    expect(item.name, 'IMG 0001.heic');
    expect(item.mime, 'image/heic');
    expect(item.size, bytes.length);
    expect(item.ownsFile, isTrue);
    expect(await File(item.path!).readAsBytes(), bytes);

    await eventually(
      () => p.b.store[key]?.isReady ?? false,
      reason: 'the peer did not mirror the upload',
    );
    expect(await File(p.b.store[key]!.path!).readAsBytes(), bytes);

    // Without a Content-Length (chunked) it lands too.
    final c = await send(
      'POST',
      p.url('/web/items?name=notes.txt'),
      body: utf8.encode('x' * 100000),
      chunked: true,
    );
    expect(c.status, 200);
    final ckey = (jsonDecode(utf8.decode(c.body)) as Map)['key'] as String;
    expect(p.a.store[ckey]!.size, 100000);

    expect((await send('POST', p.url('/web/items'), body: [1])).status, 400);
  });

  test('a text post lands as a text item', () async {
    p = await Pair.start();
    final r = await send(
      'POST',
      p.url('/web/text'),
      body: utf8.encode('first line\nsecond'),
    );
    expect(r.status, 200);
    final key = (jsonDecode(utf8.decode(r.body)) as Map)['key'] as String;
    final item = p.a.store[key]!;
    expect(item.kind, ItemKind.text);
    expect(item.name, 'first line');
    expect(await File(item.path!).readAsString(), 'first line\nsecond');
    await eventually(() => p.b.store[key]?.isReady ?? false);

    expect(
      (await send('POST', p.url('/web/text'), body: [32, 10])).status,
      400,
    );
    expect(
      await rawStatus(
        p.a.port,
        'POST /web/text HTTP/1.1\r\nHost: 127.0.0.1\r\n'
        'Content-Length: ${WebHost.maxTextBytes + 1}\r\n\r\n',
      ),
      contains('413'),
    );
  });

  test('delete takes back an own item, not a mirror', () async {
    p = await Pair.start();
    final mine = await p.a.addText('mine');
    final theirs = await p.b.addText('theirs');
    await eventually(() => p.a.store[theirs.key] != null);

    expect((await send('DELETE', p.url('/web/items/${mine.key}'))).status, 204);
    expect(p.a.store[mine.key], isNull);
    expect(
      (await send('DELETE', p.url('/web/items/${theirs.key}'))).status,
      403,
    );
    expect(p.a.store[theirs.key], isNotNull);
    expect((await send('DELETE', p.url('/web/items/${mine.key}'))).status, 404);
  });

  test('what is gone or never was answers 404', () async {
    p = await Pair.start();
    final note = await p.a.addText('soon gone');
    expect((await get(p.url('/web/items/${note.key}'))).status, 200);
    p.a.remove(note.key);
    expect((await get(p.url('/web/items/${note.key}'))).status, 404);
    expect((await get(p.url('/web/items/${p.a.id}/nope'))).status, 404);
    expect((await get(p.url('/web/items/${p.a.id}'))).status, 404);
    expect((await get(p.url('/web/nothing'))).status, 404);
    expect((await get(p.url('/favicon.ico'))).status, 404);
    expect((await send('PUT', p.url('/web/shelf'))).status, 404);
  });

  test('an upload over the cap is refused with 413', () async {
    p = await Pair.start(maxItemBytes: 64 * 1024);
    // Announced up front: refused before a byte of it is read.
    expect(
      await rawStatus(
        p.a.port,
        'POST /web/items?name=big.bin HTTP/1.1\r\nHost: 127.0.0.1\r\n'
        'Content-Length: ${128 * 1024}\r\n\r\n',
      ),
      contains('413'),
    );
    // Chunked, so only the bytes themselves can tell: cut off at the cap.
    expect(
      await rawStatus(
        p.a.port,
        'POST /web/items?name=big.bin HTTP/1.1\r\nHost: 127.0.0.1\r\n'
        'Transfer-Encoding: chunked\r\n\r\n',
        chunkedBody(96 * 1024, 8 * 1024),
      ),
      contains('413'),
    );
    expect(p.a.items, isEmpty);
    // The half-written file went with its refusal.
    final own = Directory('${p.root.path}/mac/${p.a.id}');
    await eventually(
      () => !own.existsSync() || own.listSync().isEmpty,
      reason: 'item dir left behind',
    );
    // Under the cap still lands.
    final ok = await send(
      'POST',
      p.url('/web/items?name=small.bin'),
      body: List.filled(1024, 1),
    );
    expect(ok.status, 200);
  });

  test('addStream drops a body that ends short of its length', () async {
    p = await Pair.start();
    await expectLater(
      p.a.store.addStream(
        Stream.fromIterable([
          [1, 2, 3],
        ]),
        'cut.bin',
        expectedSize: 10,
      ),
      throwsFormatException,
    );
    expect(p.a.items, isEmpty);
    final item = await p.a.store.addStream(
      Stream.fromIterable([
        [1, 2],
        [3],
      ]),
      'ok.bin',
    );
    expect(item.size, 3);
    expect(await File(item.path!).readAsBytes(), [1, 2, 3]);
  });

  test('webUrls lead with the .local name, then each IPv4', () async {
    p = await Pair.start();
    final urls = await p.a.webUrls;
    expect(urls, isNotEmpty);
    final host = await localHostName();
    expect(host, isNot(contains('.')));
    expect(host, host.toLowerCase());
    if (host != 'localhost') {
      expect(urls.first, 'http://$host.local:${p.a.port}/');
    }
    for (final u in urls.skip(host == 'localhost' ? 0 : 1)) {
      expect(u, matches(RegExp(r'^http://\d+\.\d+\.\d+\.\d+:\d+/$')));
    }
  });

  test(
    'start takes a preferred port, or any free one when it is taken',
    () async {
      p = await Pair.start();
      final taken = await ServerSocket.bind(InternetAddress.anyIPv6, 0);
      final dir = Directory('${p.root.path}/third');
      final third = await PlopNode.start(
        dir: dir,
        discovery: StaticDiscovery(),
        name: 'third',
        port: taken.port,
      );
      expect(third.port, isNot(taken.port));
      await third.stop();
      await taken.close();
      final fourth = await PlopNode.start(
        dir: dir,
        discovery: StaticDiscovery(),
        name: 'fourth',
        port: taken.port,
      );
      expect(fourth.port, taken.port);
      await fourth.stop();
    },
  );
}
