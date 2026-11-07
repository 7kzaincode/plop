import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'discovery.dart';
import 'item.dart';
import 'node_server.dart';
import 'plop_node.dart';
import 'shelf_store.dart';

/// Header the page sets on every request that changes something. A form
/// or a no-cors fetch from any other site reaches these routes through the
/// user's browser too, but neither can set a header of its own: that takes
/// a CORS preflight, which this server never answers.
const webHeader = 'x-plop-web';

/// Header a DELETE carries the token its upload was answered with.
const webTokenHeader = 'x-plop-token';

/// Port the app asks for first: p-l-o-p on a phone keypad, so the address a
/// phone has to type is one worth remembering. Any free port when taken.
const defaultWebPort = 7567;

/// The mDNS host name every desktop plop with the web shelf on tries to
/// answer for, on [defaultWebPort], so one address (and one home-screen
/// icon) reaches the shelf through whichever of the user's computers is
/// on. Host names are unique on mDNS: one computer holds it, the others
/// wait and take it over when that one goes (the app's lib/alias.dart).
const sharedHost = 'plop.local';

/// A one-page web shelf for devices without the app (iPhones, mostly),
/// served on the node's own port once [enabled]. The page lists everything
/// this node knows, own items and mirrors alike, hands any of it out
/// through this node, and takes uploads as this node's own items.
///
/// plop peers never call these routes, so the /v1 rule that mirrors are not
/// re-served still holds between nodes: a phone on this page is a user of
/// this device, not a peer, and what it grabs comes off this device's shelf
/// the way a tap in the window would.
class WebHost {
  WebHost(this.node);

  final PlopNode node;

  /// Off until the app turns it on; a disabled host answers 404 to all of
  /// its routes, so a bare node looks like it always did.
  bool enabled = false;

  /// The PNG behind /icon.png: the app's icon. A black pixel until set.
  Uint8List iconPng = _blackPixel;

  /// Text items up to this size travel inline in the shelf list, so a tap
  /// can copy them without a fetch first: on plain http a browser offers no
  /// async clipboard, and the fallback it does have only works inside the
  /// tap itself.
  static const maxInlineText = 64 * 1024;

  /// Inline text in one shelf answer, all items together; texts past it are
  /// fetched on a tap instead. Peers can fill the shelf with small texts,
  /// and every poll from every phone would carry all of them, as would the
  /// cache behind it.
  int maxInlineTotal = 1 << 20;

  /// Longest text /web/text takes; it is read into memory whole.
  static const maxTextBytes = 1 << 20;

  // Anyone on the LAN can upload here, so what uploads may take is bounded:
  // descriptors (each upload holds a socket and an open file, and a GUI
  // app starts with 256), the disk, and the shelf every peer mirrors.

  /// Uploads, files and texts, in progress at once; more get 503 and the
  /// page tries again shortly.
  int maxUploads = 4;

  /// Longest wait for the next piece of an upload's body before it is
  /// dropped (408), so a stalled sender does not hold a slot for good.
  Duration uploadIdle = const Duration(seconds: 30);

  /// Largest single upload, under the node's own item cap: a phone's
  /// longest video fits, a runaway or hostile sender stops early.
  int maxUploadBytes = 8 << 30;

  /// What uploads from the page may add up to while on the shelf, in
  /// bytes and in items; past either, more get 507 until some expire.
  int maxLiveBytes = 16 << 30;
  int maxLiveItems = 200;

  /// Uploads in progress now.
  int get uploading => _uploading;
  int _uploading = 0;

  /// Bytes promised to uploads in progress: what each says it will send,
  /// or for one that does not say, all it may.
  int _reserved = 0;

  /// Items the page put up that may still be on the shelf, by key, with
  /// the token that takes each back. Only the browser that uploaded an
  /// item gets its token, so a phone can take back what it put up and
  /// nothing else: not another phone's, and not what the desktop's own user
  /// shared, which nothing on /v1 can remove either.
  final _uploaded = <String, String>{};

  /// Keys of the items the page put up that are still on the shelf. They
  /// are this node's own items, but came from another device (a phone
  /// without the app), so the app treats them as arrivals: grabbing the
  /// newest, copying arrivals.
  Set<String> get uploads => {
    for (final k in _uploaded.keys)
      if (node.store[k] != null) k,
  };

  /// Whether [key] is an item the page put up, still on the shelf.
  bool isUpload(String key) =>
      _uploaded.containsKey(key) && node.store[key] != null;

  /// Fires when an item becomes one of [uploads]. The store announced the
  /// item a moment before, as one of this node's own; this is when it is
  /// known to be from the page.
  Stream<void> get changes => _changes.stream;
  final _changes = StreamController<void>.broadcast();

  final _texts = <String, String>{}; // key -> body of an inlined text item

  /// Answers one request to a path outside /v1. Always closes the response.
  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    try {
      await _route(req);
    } catch (_) {
      // Whatever already went out stays; what can still be said is 500.
      try {
        res.statusCode = HttpStatus.internalServerError;
      } catch (_) {}
    }
    try {
      await res.close();
    } catch (_) {}
  }

  /// This shelf at its other addresses, as a JSON list for the page: a
  /// home-screen app on an iPhone or iPad opens a file from one of them in
  /// Safari's sheet over itself, which has Save to Files and Done; from its
  /// own address the file would take over the app with no way back.
  Future<String> _others(HttpRequest req) async {
    final port = req.connectionInfo?.localPort ?? req.requestedUri.port;
    final (ips, host) = await (localIPv4s(), localHostName()).wait;
    // The name first: an iPhone's sheet has been seen to hang on an
    // address it reaches fine by name.
    final hosts = [
      if (host.isNotEmpty && host != 'localhost') '$host.local',
      ...ips,
    ];
    // Into a <script>: nothing in it may close the tag.
    return jsonEncode([for (final h in hosts) 'http://$h:$port'])
        .replaceAll('<', r'\u003c');
  }

  Future<void> _route(HttpRequest req) async {
    final res = req.response;
    final reads = req.method == 'GET' || req.method == 'HEAD';
    if (!_sameOrigin(req) ||
        !reads && req.headers[webHeader]?.singleOrNull != '1') {
      claimBody(req); // refused without reading it
      res.statusCode = HttpStatus.forbidden;
      return;
    }
    // HEAD answers as GET would; dart:io leaves the body out.
    final method = req.method == 'HEAD' ? 'GET' : req.method;
    switch ((method, req.uri.pathSegments)) {
      case ('GET', []):
        res.headers
          ..contentType = ContentType.html
          ..set(HttpHeaders.cacheControlHeader, 'max-age=60');
        res.write(
          _page
              .replaceAll('{{name}}', htmlEscape.convert(node.store.nodeName))
              .replaceAll('{{others}}', await _others(req)),
        );
      case ('GET', ['manifest.webmanifest']):
        res.headers
          ..contentType = ContentType(
            'application',
            'manifest+json',
            charset: 'utf-8',
          )
          ..set(HttpHeaders.cacheControlHeader, 'max-age=3600');
        res.write(jsonEncode(_manifest));
      case ('GET', ['icon.png']):
        res.headers
          ..contentType = ContentType('image', 'png')
          ..set(HttpHeaders.cacheControlHeader, 'max-age=86400');
        res.contentLength = iconPng.length;
        res.add(iconPng);
      case ('GET', ['web', 'shelf']):
        _noStore(res);
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(await _shelf()));
      // The name after the id, if any, is only for Safari's sheet, which
      // names a file by its URL's last segment.
      case ('GET', ['web', 'items', final origin, final id, ...]):
        await _download(req, itemKey(origin, id), head: req.method == 'HEAD');
      case ('POST', ['web', 'items']):
        await _upload(req);
      case ('POST', ['web', 'text']):
        await _text(req);
      case ('DELETE', ['web', 'items', final origin, final id]):
        _noStore(res);
        final key = itemKey(origin, id);
        final token = _uploaded[key];
        if (node.store[key] == null) {
          res.statusCode = HttpStatus.notFound;
        } else if (token == null ||
            !_same(req.headers[webTokenHeader]?.singleOrNull, token)) {
          res.statusCode = HttpStatus.forbidden; // only its uploader removes
        } else {
          _uploaded.remove(key);
          node.remove(key);
          res.statusCode = HttpStatus.noContent;
        }
      default:
        res.statusCode = HttpStatus.notFound;
    }
  }

  /// False for a request that says it comes from a page on another origin.
  /// Browsers send Origin with every write, and with reads made through
  /// CORS; the page's own requests carry `http://` plus the Host they went
  /// to. Requests with no Origin (navigations, nodes, curl) pass.
  static bool _sameOrigin(HttpRequest req) {
    final origin = req.headers['origin'];
    if (origin == null) return true;
    final host = req.headers[HttpHeaders.hostHeader];
    return origin.length == 1 &&
        host?.length == 1 &&
        origin.single.toLowerCase() == 'http://${host!.single.toLowerCase()}';
  }

  /// [a] == [b], in a time that does not depend on where they differ.
  static bool _same(String? a, String b) {
    if (a == null || a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < b.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// [ShelfStore.stillThere] within [NodeServer.statBudget]: a check that
  /// runs over counts as present, as it does for /v1, and the file's own
  /// open says otherwise if it is gone.
  Future<bool> _present(ShelfItem i) => node.store
      .stillThere(i)
      .timeout(NodeServer.statBudget, onTimeout: () => true);

  static void _noStore(HttpResponse res) =>
      res.headers.set(HttpHeaders.cacheControlHeader, 'no-store');

  /// Every item this node knows, newest first, with a text item's body
  /// inline while it is small and already here, up to [maxInlineTotal].
  Future<List<Map<String, Object>>> _shelf() async {
    final out = <Map<String, Object>>[];
    final inlined = <String>{};
    var budget = maxInlineTotal;
    for (final i in node.items) {
      // A snapshot: an item can leave while a stat or a read is in flight.
      if (!await _present(i) || node.store[i.key] != i) continue;
      final text = i.size <= budget ? await _textOf(i) : null;
      if (text != null) {
        inlined.add(i.key);
        budget -= i.size;
      }
      out.add({
        'key': i.key,
        'name': i.name,
        'size': i.size,
        'mime': i.mime,
        'kind': i.kind.name,
        'ttlMs': i.remaining.inMilliseconds,
        'from': i.originName,
        'ready': i.isReady,
        // 0..1 while this node copies it over from its sender.
        'progress': ?i.progress,
        if (i.originId == node.id) 'receivedBy': i.receivedBy.length,
        // The page put it up here, so this node holds the token that takes
        // it back. With [sharedHost] the page may be talking to another
        // computer than the one that took an upload: that one lists it as
        // a mirror without this, and the page shows no × it cannot honour.
        if (_uploaded.containsKey(i.key)) 'removable': true,
        'text': ?text,
      });
    }
    // Only what went out stays cached: what expired, and what no longer
    // fits, goes.
    _texts.removeWhere((k, _) => !inlined.contains(k));
    return out;
  }

  /// Takes one of the [maxUploads] slots, or answers 503 (or 507 when the
  /// page's items fill [maxLiveItems] already) and returns false.
  bool _startUpload(HttpResponse res) {
    _uploaded.removeWhere((k, _) => node.store[k] == null);
    if (_uploading >= maxUploads) {
      res
        ..statusCode = HttpStatus.serviceUnavailable
        ..headers.set(HttpHeaders.retryAfterHeader, '2');
      return false;
    }
    if (_uploaded.length + _uploading >= maxLiveItems) {
      res.statusCode = HttpStatus.insufficientStorage;
      return false;
    }
    _uploading++;
    return true;
  }

  /// `{"key": …, "token": …}`, the token being what a DELETE needs.
  void _answerUpload(HttpResponse res, ShelfItem item) {
    final token = randomId(16);
    _uploaded[item.key] = token;
    _changes.add(null);
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode({'key': item.key, 'token': token}));
  }

  /// Bytes the page's items may still add, after those on the shelf and
  /// those promised to uploads in progress.
  int _room() {
    var used = _reserved;
    for (final k in _uploaded.keys) {
      used += node.store[k]?.size ?? 0;
    }
    return max(0, maxLiveBytes - used);
  }

  Future<String?> _textOf(ShelfItem i) async {
    if (i.kind != ItemKind.text || !i.isReady || i.size > maxInlineText) {
      return null;
    }
    try {
      return _texts[i.key] ??= await File(i.path!).readAsString();
    } catch (_) {
      return null; // expired between the listing and the read
    }
  }

  Future<void> _download(
    HttpRequest req,
    String key, {
    required bool head,
  }) async {
    final res = req.response;
    _noStore(res);
    // A file shared in place and changed since leaves the shelf instead,
    // as it does for peers.
    final item = node.store[key];
    if (item == null || !await _present(item)) {
      res.statusCode = HttpStatus.notFound;
      return;
    }
    final mime = safeMime(item.mime);
    // Whatever the bytes are, they never run as a page from this origin: a
    // peer's HTML or SVG, opened in a tab, would otherwise script the
    // shelf. A photo, video or song can't script, and Safari shows none of
    // them under a sandbox, only a blank page.
    if (!_media.hasMatch(mime)) {
      res.headers.set('content-security-policy', 'sandbox');
    }
    res.headers
      // Checked again here, not only where a peer's list is read: this is
      // where a bad one would do harm.
      ..set(HttpHeaders.contentTypeHeader, mime)
      ..set('content-disposition', _attachment(transferName(item)))
      // A phone's video player reads a file in ranges, and plays nothing
      // from a server that can't send them.
      ..set(HttpHeaders.acceptRangesHeader, 'bytes');
    // HEAD is answered from what the shelf knows: a mirror not copied yet
    // would otherwise be copied whole just to say how big it is.
    if (head) {
      res.contentLength = item.size;
      return;
    }
    final String path;
    try {
      path = await node.fetch(key); // a mirror not copied yet is copied now
    } catch (_) {
      // Expired meanwhile, or its sender cannot be reached.
      res.statusCode = node.store[key] == null
          ? HttpStatus.notFound
          : HttpStatus.badGateway;
      return;
    }
    // The item captured above is the one served, even if it expires the
    // moment its copy lands, and its file is opened at once: should that
    // expiry delete it, an open file still reads to its end on macOS and
    // Linux, and on Windows the delete waits.
    final RandomAccessFile f;
    try {
      f = await File(path).open();
    } on FileSystemException {
      res.statusCode = HttpStatus.notFound;
      return;
    }
    final int length;
    try {
      length = await f.length();
    } catch (_) {
      await f.close();
      rethrow;
    }
    final range = byteRange(req.headers.value(HttpHeaders.rangeHeader), length);
    if (range == null) {
      res.contentLength = length;
      await _chunks(f, 0, length).pipe(res);
      return;
    }
    final (start, end) = range;
    if (start > end) {
      await f.close();
      res
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
      return;
    }
    res
      ..statusCode = HttpStatus.partialContent
      ..headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$length')
      ..contentLength = end - start + 1;
    await _chunks(f, start, end + 1).pipe(res);
  }

  static final _media = RegExp(r'^(image/(?!svg)|video/|audio/)');

  /// [f] from [start] to [end], read as the response takes it, then
  /// closed; closed too when the browser hangs up first.
  static Stream<List<int>> _chunks(
    RandomAccessFile f,
    int start,
    int end,
  ) async* {
    try {
      await f.setPosition(start);
      for (var left = end - start; left > 0;) {
        final chunk = await f.read(min(64 * 1024, left));
        if (chunk.isEmpty) return;
        left -= chunk.length;
        yield chunk;
      }
    } finally {
      await f.close();
    }
  }

  Future<void> _upload(HttpRequest req) async {
    final res = req.response;
    _noStore(res);
    final body = claimBody(req);
    // Shown on every device's shelf: one plain line of at most the length
    // a peer's name is cut to.
    final raw = req.uri.queryParameters['name'] ?? '';
    final name = cleanName(raw, max: ShelfStore.maxNameLength);
    if (isBlankLabel(raw)) {
      res.statusCode = HttpStatus.badRequest;
      return;
    }
    final length = req.contentLength; // -1 when chunked
    final sizeCap = min(maxUploadBytes, node.store.maxItemBytes);
    if (length > sizeCap) {
      res.statusCode = HttpStatus.requestEntityTooLarge;
      return;
    }
    if (!_startUpload(res)) return;
    final room = _room();
    final cap = min(sizeCap, room);
    final promised = length < 0 ? cap : length;
    _reserved += promised;
    try {
      if (length > room) {
        throw ItemTooLargeException(length, room);
      }
      final item = await node.store.addStream(
        body.timeout(uploadIdle),
        name,
        expectedSize: length < 0 ? null : length,
        maxBytes: cap,
      );
      _answerUpload(res, item);
    } on ItemTooLargeException catch (e) {
      // The rest of the body stays unread; see claimBody. Too big for any
      // upload is 413; too big for what the page's items have left, 507.
      res.statusCode = e.max < sizeCap
          ? HttpStatus.insufficientStorage
          : HttpStatus.requestEntityTooLarge;
    } on FormatException {
      res.statusCode = HttpStatus.badRequest; // ended short of its length
    } on TimeoutException {
      res.statusCode = HttpStatus.requestTimeout;
    } finally {
      _reserved -= promised;
      _uploading--;
    }
  }

  Future<void> _text(HttpRequest req) async {
    final res = req.response;
    _noStore(res);
    final body = claimBody(req);
    if (req.contentLength > maxTextBytes) {
      res.statusCode = HttpStatus.requestEntityTooLarge;
      return;
    }
    if (!_startUpload(res)) return;
    try {
      final buf = BytesBuilder(copy: false);
      await for (final chunk in body.timeout(uploadIdle)) {
        buf.add(chunk);
        if (buf.length > maxTextBytes) {
          res.statusCode = HttpStatus.requestEntityTooLarge;
          return;
        }
      }
      if (buf.length > _room()) {
        res.statusCode = HttpStatus.insufficientStorage;
        return;
      }
      final text = utf8.decode(buf.takeBytes(), allowMalformed: true);
      if (text.trim().isEmpty) {
        res.statusCode = HttpStatus.badRequest;
        return;
      }
      final item = await node.addText(text);
      _answerUpload(res, item);
    } on TimeoutException {
      res.statusCode = HttpStatus.requestTimeout;
    } finally {
      _uploading--;
    }
  }
}

/// The one byte range a `Range: bytes=…` header asks for in a body of
/// [length], inclusive: null for none, or a form this does not serve (a
/// list of ranges, another unit), which gets the whole body; start > end
/// when it lies past the end.
(int, int)? byteRange(String? header, int length) {
  final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header?.trim() ?? '');
  if (m == null) return null;
  final (a, b) = (int.tryParse(m[1]!), int.tryParse(m[2]!));
  if (a == null) {
    if (b == null) return null;
    // The last b bytes.
    return b == 0 ? (1, 0) : (max(0, length - b), length - 1);
  }
  return (a, min(b ?? length - 1, length - 1));
}

/// `attachment; filename="…"; filename*=UTF-8''…`: the plain form for old
/// browsers, with anything outside printable ASCII replaced, and the
/// RFC 5987 form every current one reads, which keeps the real name bar
/// what [cleanName] takes out.
String _attachment(String raw) {
  final name = cleanName(raw, max: ShelfStore.maxNameLength);
  // By code point, so an emoji (two UTF-16 units) becomes one `_`.
  final plain = name.replaceAll(
    RegExp(r'[^\x20-\x7e]|["\\]', unicode: true),
    '_',
  );
  // encodeComponent leaves `!'()*` alone; 5987 wants them encoded.
  final star = Uri.encodeComponent(name).replaceAllMapped(
    RegExp(r"[!'()*]"),
    (m) => '%${m[0]!.codeUnitAt(0).toRadixString(16).toUpperCase()}',
  );
  return "attachment; filename=\"$plain\"; filename*=UTF-8''$star";
}

const _manifest = {
  'name': 'plop',
  'short_name': 'plop',
  'start_url': '/',
  'display': 'standalone',
  'background_color': '#0A0A0A',
  'theme_color': '#0A0A0A',
  // The app's icon, which is 1024 px; browsers scale it to what they need.
  'icons': [
    {'src': '/icon.png', 'sizes': '1024x1024', 'type': 'image/png'},
  ],
};

/// A 1x1 black PNG, for a host that was never handed the app's icon.
final _blackPixel = Uint8List.fromList(const [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xde, 0x00, 0x00, 0x00, //
  0x0c, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0x60, 0x60, 0x60, 0x00, //
  0x00, 0x00, 0x04, 0x00, 0x01, 0xc8, 0xea, 0xeb, 0xf9, 0x00, 0x00, 0x00, //
  0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]);

// The page. One file, no build step, nothing fetched from outside the LAN.
// Served over plain http, so the browser gives it no secure-context APIs
// (navigator.share, navigator.clipboard, install prompts): copying goes
// through execCommand inside the tap, images open full-screen to be held
// and saved, other files download, and share() is used only where a
// browser does offer it. Every write sets the x-plop-web header (see
// webHeader). `{{name}}` is this device's name.
const _page = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="#0A0A0A">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="plop">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="apple-touch-icon" href="/icon.png">
<link rel="icon" href="/icon.png">
<title>plop · {{name}}</title>
<style>
:root{--bg:#0a0a0a;--text:#ededed;--dim:#a1a1a1;--faint:#7a7a7a;--line:rgba(255,255,255,.08);--border:rgba(255,255,255,.14);--pressed:rgba(255,255,255,.09);--warn:#e5484d}
*{box-sizing:border-box;margin:0;padding:0}
html,body{background:var(--bg);color:var(--text);font:16px/1.3 ui-monospace,"SF Mono",Menlo,monospace;-webkit-text-size-adjust:100%;-webkit-tap-highlight-color:transparent}
body{min-height:100vh;min-height:100dvh;display:flex;flex-direction:column;padding:0 env(safe-area-inset-right) 0 env(safe-area-inset-left)}
button{font:inherit;color:inherit;background:none;border:0;cursor:pointer;touch-action:manipulation}
header{display:flex;align-items:center;gap:8px;padding:calc(12px + env(safe-area-inset-top)) 16px 12px;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:1}
h1{font-size:16px;font-weight:500;flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
h1 span{color:var(--dim);font-weight:400}
.off h1 span{color:var(--warn)}
.btn{padding:6px 12px;border:1px solid var(--border);border-radius:6px;line-height:1.2;white-space:nowrap}
.btn:active{background:var(--pressed)}
#list{flex:1;display:flex;flex-direction:column}
.row{flex:none;display:flex;align-items:center;gap:12px;padding:12px 8px 12px 16px;position:relative;cursor:pointer;user-select:none;-webkit-user-select:none}
.row:active{background:var(--pressed)}
.main{flex:1;min-width:0}
.name{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.meta{font-size:13px;color:var(--dim);margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.lead{flex:none;width:32px;height:32px;display:block}
.a{flex:none;width:40px;height:40px;margin:-4px 0;display:flex;align-items:center;justify-content:center;color:var(--dim);border-radius:8px}
.a svg{width:20px;height:20px;fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
.a:active{color:var(--text);background:var(--pressed)}
.time{color:var(--dim);font-variant-numeric:tabular-nums;min-width:44px;text-align:right;padding-right:4px}
.time.ending{color:var(--warn)}
.x{color:var(--dim);font-size:20px;line-height:1;padding:8px 10px;margin:-8px -4px}
.x:active{color:var(--text)}
#bar{position:sticky;bottom:0;display:flex;gap:8px;padding:10px 12px calc(10px + env(safe-area-inset-bottom));border-top:1px solid var(--line);background:var(--bg);z-index:1}
.gb{flex:1;min-width:0;height:46px;display:flex;align-items:center;justify-content:center;gap:8px;border:1px solid var(--border);border-radius:10px;font-size:14px;white-space:nowrap}
.gb svg{flex:none;width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
.gb:active{background:var(--pressed)}
.bar{position:absolute;left:0;right:0;bottom:0;height:1px;background:var(--line)}
.bar i{display:block;height:1px;width:100%;background:var(--faint);transition:width 1s linear}
.bar.live i{background:var(--text);transition:none}
.empty{flex:1;display:flex;align-items:center;justify-content:center;text-align:center;color:var(--faint);font-size:13px;line-height:1.7;padding:32px}
#hint{display:none;align-items:center;gap:8px;padding:12px 12px 12px 16px;border-top:1px solid var(--line);color:var(--dim);font-size:13px}
#hint.on{display:flex}
#hint span{flex:1}
#hint b{color:var(--text);font-weight:400}
#toast{position:fixed;left:50%;bottom:calc(84px + env(safe-area-inset-bottom));transform:translateX(-50%);max-width:calc(100vw - 32px);padding:8px 12px;background:#161616;border:1px solid #2a2a2a;border-radius:8px;font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;opacity:0;transition:opacity .15s;pointer-events:none;z-index:3}
#toast.on{opacity:1}
#sheet,#view{display:none;position:fixed;inset:0;background:rgba(0,0,0,.7);z-index:2}
#sheet.on{display:flex;align-items:flex-end;justify-content:center}
#sheet form{width:100%;max-width:560px;padding:16px 16px calc(16px + env(safe-area-inset-bottom));background:#111;border:1px solid #2a2a2a;border-bottom:0;border-radius:12px 12px 0 0;display:flex;flex-direction:column;gap:12px}
textarea{width:100%;min-height:120px;padding:10px;font:inherit;color:var(--text);background:var(--bg);border:1px solid var(--border);border-radius:6px;resize:none;outline:none}
textarea:focus{border-color:var(--dim)}
.actions{display:flex;justify-content:flex-end;gap:8px}
.ghost{color:var(--dim);padding:6px 12px}
#sheet.show .btn{display:none}
#view.on{display:flex;flex-direction:column;background:var(--bg)}
#view img{flex:1;min-height:0;width:100%;object-fit:contain;padding:calc(16px + env(safe-area-inset-top)) 16px 16px;-webkit-touch-callout:default;-webkit-user-select:auto;user-select:auto}
#view .foot{display:flex;flex-direction:column;gap:12px;padding:12px 12px calc(10px + env(safe-area-inset-bottom));border-top:1px solid var(--line)}
#how{text-align:center;color:var(--dim);font-size:14px;line-height:1.5}
#how b{color:var(--text);font-weight:500}
#view .vb{display:flex;gap:8px}
input[type=file]{display:none}
</style>
</head>
<body>
<header>
<h1>plop <span>· {{name}}</span></h1>
<button class="btn" id="install" hidden>install</button>
</header>
<div id="list"></div>
<div id="hint"><span>add plop to your home screen: <b>share › add to home screen</b></span><button class="x" id="hintx" aria-label="dismiss">×</button></div>
<nav id="bar"><button class="gb" id="camera"><svg viewBox="0 0 24 24"><path d="M4.5 8A1.5 1.5 0 0 1 6 6.5h2.2l1.4-2h4.8l1.4 2H18A1.5 1.5 0 0 1 19.5 8v9.5A1.5 1.5 0 0 1 18 19H6a1.5 1.5 0 0 1-1.5-1.5z"/><circle cx="12" cy="12.6" r="3.3"/></svg>camera</button><button class="gb" id="photo"><svg viewBox="0 0 24 24"><rect x="3.5" y="4.5" width="17" height="15" rx="2.5"/><circle cx="9" cy="10" r="1.8"/><path d="M20.5 15.5l-5-5-9 9"/></svg>photo</button><button class="gb" id="add"><svg viewBox="0 0 24 24"><path d="M13.5 3.5H7A1.5 1.5 0 0 0 5.5 5v14A1.5 1.5 0 0 0 7 20.5h10a1.5 1.5 0 0 0 1.5-1.5V8.5z"/><path d="M13.5 3.5v5h5"/></svg>file</button><button class="gb" id="paste"><svg viewBox="0 0 24 24"><rect x="5.5" y="5" width="13" height="15.5" rx="2"/><path d="M9 5V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v1"/></svg>paste</button></nav>
<input type="file" id="pics" accept="image/*,video/*" multiple>
<input type="file" id="shot" accept="image/*" capture="environment">
<input type="file" id="file" multiple>
<svg width="0" height="0" style="position:absolute" aria-hidden="true"><defs><clipPath id="bk"><path d="M7.04 1.28L24.96 1.28C28.48 1.28 29.76 2.88 29.92 6.08L31.2 24.32C31.68 29.44 29.44 31.04 26.24 29.44C20.48 26.88 11.52 26.88 5.76 29.44C2.56 31.04 0.32 29.44 0.8 24.32L2.08 6.08C2.24 2.88 3.52 1.28 7.04 1.28Z"/></clipPath></defs></svg>
<div id="sheet"><form id="textform"><textarea id="text" placeholder="paste or type, then plop"></textarea><div class="actions"><button type="button" class="ghost" id="cancel">cancel</button><button type="submit" class="btn">plop</button></div></form></div>
<div id="view"><img id="pic" alt=""><div class="foot"><div id="how"></div><div class="vb"><button class="gb" id="dl">save to files</button><button class="gb" id="close">done</button></div></div></div>
<div id="toast"></div>
<script>
'use strict';
const $ = id => document.getElementById(id);
const list = $('list'), sheet = $('sheet'), ta = $('text'), view = $('view');
const store = {
  get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
};
// Items this browser put up, by key, with when and the token that takes
// each back: they get a × here, and a key is forgotten only once the shelf
// has gone a while without it. The × shows only where the shelf says the
// item is removable, which only the computer that took the upload does:
// through plop.local another of the user's computers may be answering,
// and it has no token to check. Kept all the same, for when that one
// answers again.
const mine = new Map((() => {
  try { return Object.entries(JSON.parse(store.get('plop.mine') || '{}')); } catch (e) { return []; }
})().filter(([, v]) => v && typeof v.token === 'string' && typeof v.at === 'number'));
const seen = new Map();  // key -> {expires, total}: countdowns between polls
const blobs = new Map(); // key -> Blob fetched for share(), kept for a retry
const asked = new Map(); // key -> when it was tapped before its bytes were here
let items = [], byKey = new Map(), uploads = [], seq = 0, sig = '', polling = false, again = false, pollTimer, toastTimer, viewing;
// Since when the shelf has not answered. Quiet for DOWN_MS, the page
// reloads once something answers again: through plop.local that may be another of
// the user's computers, now holding the name, and the reload brings its
// page. Not before: a reload that nothing answers strands a home-screen
// app on the browser's error page, with no way to try again.
const DOWN_MS = 5000;
let downSince = 0;
const mineHere = it => mine.has(it.key) && it.removable === true;

const esc = s => String(s).replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'})[c]);
// Names as they are, as safeLabel has them: controls, bidi overrides and
// isolates and line separators show as _, so a peer's "invoice\u202Efdp.exe"
// cannot show as "invoiceexe.pdf"; other invisible marks go.
const clean = s => String(s).replace(/[\u0000-\u001f\u007f-\u009f\u2028-\u202e\u2066-\u2069]/g, '_').replace(/[\u061c\u200b\u200e\u200f\u2060-\u2064\u206a-\u206f\ufeff]/g, '');
const saveMine = () => store.set('plop.mine', JSON.stringify(Object.fromEntries(mine)));
const url = it => '/web/items/' + it.key;
// This shelf at its other addresses (see _others).
const OTHERS = {{others}}.filter(o => o !== location.origin);
// The first of them this phone reaches, found once the page is up, so a
// tap doesn't open the sheet on one that never loads.
let other = null;
(async () => {
  for (const o of OTHERS) {
    try {
      await fetch(o + '/icon.png', {mode: 'no-cors', cache: 'no-store', signal: AbortSignal.timeout(2500)});
      other = o;
      return;
    } catch (e) {}
  }
})();
const fileName = it => it.kind === 'folder' ? it.name + '.zip' : it.kind === 'text' ? 'text.txt' : it.name;
const isImage = it => it.kind === 'file' && /^image\//.test(it.mime);
const canShare = f => !!(navigator.share && navigator.canShare && navigator.canShare({files: [f]}));
const done = new Map(); // key -> 'copied' or 'saved', said on the row as the app does

// ------------------------------------------------------------- the rows, as the app draws them

// File types, each with its own glyph on a white tile shaped like the
// logo's bucket (the app's type_icons.dart, redrawn in SVG).
const TYPES = {
  image: 'jpg jpeg png gif webp heic heif bmp tif tiff svg ico raw dng avif',
  video: 'mp4 mov avi mkv webm m4v wmv', audio: 'mp3 wav m4a aac flac ogg aiff',
  document: 'txt doc docx rtf pages odt log', pdf: 'pdf',
  code: 'py js ts jsx tsx c cc cpp h hpp java kt swift go rs rb php html css scss dart cs lua vue svelte m mm',
  sheet: 'xlsx xls csv tsv numbers ods', slides: 'pptx ppt key odp', archive: 'zip rar 7z tar gz tgz bz2 xz',
  model: 'stl obj fbx gltf glb blend 3mf step stp usdz', project: 'psd fig sketch ai xd aep prproj',
  data: 'json db sql sqlite xml yaml yml parquet toml', app: 'exe app dmg msi apk ipa deb pkg rpm',
  terminal: 'sh bash zsh bat cmd ps1 command', font: 'ttf otf woff woff2', note: 'md markdown note', web: 'url webloc website'
};
const byExt = {};
for (const [t, exts] of Object.entries(TYPES)) for (const e of exts.split(' ')) byExt[e] = t;
function typeOf(it) {
  if (it.kind === 'text') return 'document';
  if (it.kind === 'folder') return 'folder';
  const dot = it.name.lastIndexOf('.');
  const t = dot >= 0 && byExt[it.name.slice(dot + 1).toLowerCase()];
  if (t) return t;
  const m = /^(image|video|audio)\//.exec(it.mime);
  return m ? m[1] : 'other';
}
const S = 'fill="none" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"';
const GLYPHS = {
  image: '<path d="M2.5 18.5l6-8 4 5 3-3.5 6 6.5z"/><circle cx="16.5" cy="6.5" r="2"/>',
  video: '<path d="M8 5.5v13l10.5-6.5z"/>',
  audio: '<path d="M10 4.5h8v3.8h-6v9.2a3.5 3.5 0 1 1-2-3.16z"/>',
  document: '<rect x="4" y="6" width="16" height="2.4" rx="1.2"/><rect x="4" y="10.8" width="16" height="2.4" rx="1.2"/><rect x="4" y="15.6" width="10" height="2.4" rx="1.2"/>',
  code: '<path ' + S + ' d="M9 7l-5 5 5 5M15 7l5 5-5 5"/>',
  sheet: '<rect x="4" y="4" width="7" height="7" rx="1.5"/><rect x="13" y="4" width="7" height="7" rx="1.5"/><rect x="4" y="13" width="7" height="7" rx="1.5"/><rect x="13" y="13" width="7" height="7" rx="1.5"/>',
  slides: '<path d="M11 3.6a8.5 8.5 0 1 0 9.4 9.4H11z"/><path d="M13 2v9h9a9 9 0 0 0-9-9z"/>',
  archive: '<rect x="10.1" y="2.8" width="3.8" height="2.2" rx="1"/><rect x="10.1" y="6.8" width="3.8" height="2.2" rx="1"/><rect x="10.1" y="10.9" width="3.8" height="2.2" rx="1"/><rect x="10" y="14.9" width="4.1" height="6.7" rx="2"/>',
  model: '<path ' + S + ' stroke-width="2.2" d="M12 2.8l8 4.4v9.6l-8 4.4-8-4.4V7.2zM4 7.2l8 4.4 8-4.4M12 11.6v9.6"/>',
  project: '<path d="M12 3l9 5-9 5-9-5z"/><path d="M4.8 12.2 12 16.2l7.2-4 1.8 1-9 5-9-5z"/>',
  data: '<rect x="3.5" y="4" width="17" height="4.4" rx="1.3"/><rect x="3.5" y="9.8" width="17" height="4.4" rx="1.3"/><rect x="3.5" y="15.6" width="17" height="4.4" rx="1.3"/>',
  app: '<circle cx="12" cy="12" r="5.2" fill="none" stroke-width="3.2"/>' +
    [0, 45, 90, 135, 180, 225, 270, 315].map(a => '<rect x="10.4" y="1.8" width="3.2" height="4.4" rx="1" transform="rotate(' + a + ' 12 12)"/>').join(''),
  terminal: '<path ' + S + ' d="M5 7.5l4.5 4.5L5 16.5"/><rect x="11.5" y="15.3" width="7.5" height="2.4" rx="1.2"/>',
  note: '<path d="M5 4h14a1 1 0 0 1 1 1v9h-5a1 1 0 0 0-1 1v5H5a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1z"/><path d="M16 16h4l-4 4z"/>',
  web: '<g fill="none" stroke-width="2"><circle cx="12" cy="12" r="8.5"/><ellipse cx="12" cy="12" rx="3.6" ry="8.5"/><path d="M3.5 12h17"/></g>',
  folder: '<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5h4.6l2 2h8.4A1.5 1.5 0 0 1 21 8.5v9a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5z"/>',
  other: '<circle cx="12" cy="12" r="3.6"/>'
};
const LABELS = {pdf: ['PDF', 10.3], font: ['Aa', 12]};
const BUCKET = 'M7.04 1.28L24.96 1.28C28.48 1.28 29.76 2.88 29.92 6.08L31.2 24.32C31.68 29.44 29.44 31.04 26.24 29.44C20.48 26.88 11.52 26.88 5.76 29.44C2.56 31.04 0.32 29.44 0.8 24.32L2.08 6.08C2.24 2.88 3.52 1.28 7.04 1.28Z';
// Pictures already on the desktop show as themselves, in the bucket's shape.
function lead(it) {
  const t = typeOf(it);
  if (t === 'image' && it.ready && it.size <= 8 * 1024 * 1024 && !/svg/.test(it.mime)) {
    return '<svg class="lead" viewBox="0 0 32 32"><path d="' + BUCKET + '" fill="#3a3a3a"/><image href="' + url(it) +
      '" width="32" height="32" preserveAspectRatio="xMidYMid slice" clip-path="url(#bk)"/></svg>';
  }
  const l = LABELS[t];
  const glyph = l
    ? '<text x="16" y="' + (14.2 + l[1] * 0.36) + '" text-anchor="middle" font-size="' + l[1] + '" font-weight="600" font-family="-apple-system,system-ui,Helvetica,Arial,sans-serif" fill="#0a0a0a">' + l[0] + '</text>'
    : '<g transform="translate(7.7 5.8) scale(.693)" fill="#0a0a0a" stroke="#0a0a0a" stroke-width="0">' + GLYPHS[t] + '</g>';
  return '<svg class="lead" viewBox="0 0 32 32"><path d="' + BUCKET + '" fill="#f5f5f5"/>' + glyph + '</svg>';
}
const ICONS = {
  copy: '<rect x="8.5" y="8.5" width="11" height="11.5" rx="2"/><path d="M5 15.5V6a1.5 1.5 0 0 1 1.5-1.5H15"/>',
  save: '<path d="M12 4.5v14M6.5 13 12 18.5 17.5 13"/>',
  share: '<path d="M12 3.5v11M8 7.5l4-4 4 4M6.5 11v8a1.5 1.5 0 0 0 1.5 1.5h8a1.5 1.5 0 0 0 1.5-1.5v-8"/>',
  remove: '<path d="M7 7l10 10M17 7 7 17"/>'
};
const icon = (a, key) => '<button class="a" data-a="' + a + '" aria-label="' + a + '"><svg viewBox="0 0 24 24">' + ICONS[a] + '</svg></button>';
// What a row offers, first being what a tap on the row does. Pictures copy
// first, as in the app; a page from the desktop over plain http gets no
// share sheet, so files are saved instead, where they show in Files.
function actionsFor(it) {
  if (it.kind === 'text') return ['copy'];
  if (it.kind === 'folder') return ['save'];
  const share = canShare(new File([], fileName(it), {type: it.mime}));
  if (isImage(it) && !/svg/.test(it.mime)) return share ? ['copy', 'share'] : ['copy', 'save'];
  return share ? ['share'] : ['save'];
}

function size(n) {
  const u = ['B', 'KB', 'MB', 'GB'];
  let i = 0;
  while (n >= 1024 && i < 3) { n /= 1024; i++; }
  return (i === 0 || n >= 10 ? Math.round(n) : n.toFixed(1)) + ' ' + u[i];
}
function clock(ms) {
  const s = Math.max(0, Math.ceil(ms / 1000));
  if (s >= 3600) return Math.floor(s / 3600) + 'h' + String(Math.floor(s % 3600 / 60)).padStart(2, '0');
  return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
}
function toast(msg) {
  const el = $('toast');
  el.textContent = msg;
  el.classList.add('on');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('on'), Math.max(1800, 1800 + 40 * (msg.length - 20)));
}

// ------------------------------------------------------------- the shelf

async function poll() {
  if (polling) { again = true; return; }
  clearTimeout(pollTimer);
  if (document.hidden) return; // resumed by visibilitychange
  polling = true;
  const asking = Date.now();
  try {
    // A computer that went to sleep never refuses, it just stops answering:
    // without a limit the fetch would hang for as long as TCP waits.
    const ac = new AbortController(), limit = setTimeout(() => ac.abort(), 4000);
    let r;
    try { r = await fetch('/web/shelf', {cache: 'no-store', signal: ac.signal}); } finally { clearTimeout(limit); }
    if (!r.ok) throw new Error(r.status);
    // Not mid-upload or while something is open on top: those would be lost.
    if (downSince && Date.now() - downSince >= DOWN_MS && !uploads.length && !viewing && !sheet.classList.contains('on')) return location.reload();
    downSince = 0;
    items = await r.json();
    for (const it of items) { it.name = clean(it.name); it.from = clean(it.from); }
    byKey = new Map(items.map(it => [it.key, it]));
    for (const k of [...asked.keys()]) if (!byKey.has(k) || byKey.get(k).ready) asked.delete(k);
    const now = Date.now(), live = new Set();
    for (const it of items) {
      live.add(it.key);
      const s = seen.get(it.key) || {total: it.ttlMs};
      s.expires = now + it.ttlMs;
      seen.set(it.key, s);
    }
    for (const k of [...seen.keys()]) if (!live.has(k)) { seen.delete(k); blobs.delete(k); }
    for (const [k, m] of mine) if (!live.has(k) && now - m.at > 10000) mine.delete(k);
    saveMine();
    document.body.classList.remove('off');
    render();
  } catch (e) {
    if (!downSince) downSince = asking;
    document.body.classList.add('off');
  }
  polling = false;
  if (again) { again = false; return poll(); }
  pollTimer = setTimeout(poll, 2000);
}
document.addEventListener('visibilitychange', () => { if (!document.hidden) poll(); });
addEventListener('pageshow', poll);

function frac(key) {
  const s = seen.get(key);
  return s && s.total ? Math.max(0, Math.min(1, (s.expires - Date.now()) / s.total)) : 0;
}
// Rebuilds the rows only when the shelf itself changed, so a tap never
// lands on a row that was swapped out under it; tick() keeps the clocks.
function render() {
  const next = JSON.stringify([uploads.map(u => [u.id, u.wait]), items.map(it => [it.key, it.name, it.from, it.ready, mine.has(it.key), mineHere(it), done.get(it.key)])]);
  if (next === sig) return tick();
  sig = next;
  const rows = [];
  for (const u of uploads) {
    rows.push('<div class="row" data-up="' + u.id + '">' + lead({kind: 'file', name: u.name, mime: ''}) + '<div class="main"><div class="name">' + esc(u.name) +
      '</div><div class="meta">' + size(u.size) + (u.wait ? ' · waiting' : ' · uploading') + '</div></div><div class="time">' +
      (u.wait ? '' : u.pct + '%') + '</div><div class="bar live"><i style="width:' + (u.wait ? 0 : u.pct) + '%"></i></div></div>');
  }
  for (const it of items) {
    const meta = [it.kind === 'text' ? null : size(it.size), mine.has(it.key) ? 'you' : it.from, done.get(it.key)].filter(Boolean).join(' · ');
    rows.push('<div class="row" data-key="' + esc(it.key) + '">' + lead(it) + '<div class="main"><div class="name">' + esc(it.name) +
      '</div><div class="meta">' + esc(meta) + '<span class="cp"></span></div></div>' +
      actionsFor(it).map(a => icon(a)).join('') + (mineHere(it) ? icon('remove') : '') +
      '<div class="time"></div><div class="bar"><i></i></div></div>');
  }
  list.innerHTML = rows.length ? rows.join('') :
    '<div class="empty">nothing here yet<br>add something below, or plop it from any device on this wi-fi</div>';
  tick();
}
// A row whose bytes are not on the desktop yet says so while the desktop
// copies them over: an eager copy as it happens, a big item once tapped
// (the desktop fetches it only then), with how far along when it knows.
// A tap the desktop never started copying for (its sender is gone, say)
// stops saying so after a while.
function copying(it) {
  const t = it && asked.get(it.key);
  if (!it || it.ready || (it.progress == null && !(t && Date.now() - t < 10000))) return '';
  return ' · copying' + (it.progress == null ? '…' : ' ' + Math.round(it.progress * 100) + '%');
}
function tick() {
  const now = Date.now();
  for (const el of list.querySelectorAll('[data-key]')) {
    el.querySelector('.cp').textContent = copying(byKey.get(el.dataset.key));
    const s = seen.get(el.dataset.key);
    if (!s) continue;
    const left = s.expires - now, t = el.querySelector('.time'), bar = el.querySelector('.bar');
    t.textContent = clock(left);
    t.classList.toggle('ending', left < 10000);
    if (!bar.classList.contains('live')) bar.firstChild.style.width = frac(el.dataset.key) * 100 + '%';
  }
}
setInterval(tick, 1000);

list.addEventListener('click', e => {
  const row = e.target.closest('[data-key]');
  if (!row) return;
  const b = e.target.closest('[data-a]'), it = byKey.get(row.dataset.key);
  if (b && b.dataset.a === 'remove') return remove(row.dataset.key);
  if (it) act(it, b ? b.dataset.a : actionsFor(it)[0]);
});

// ------------------------------------------------------------- grabbing

function mark(it, what) {
  done.set(it.key, what);
  render();
}
async function act(it, a) {
  const key = it.key;
  if (!it.ready && it.kind !== 'text') { asked.set(key, Date.now()); tick(); }
  if (a === 'copy') return it.kind === 'text' ? copyText(it) : copyImage(it);
  if (a === 'save') return save(it);
  const name = fileName(it);
  {
    let blob = blobs.get(key);
    if (!blob) {
      try { blob = await fetchBlob(it); } catch (e) { return toast("couldn't fetch " + it.name); }
      blobs.set(key, blob);
    }
    try {
      await navigator.share({files: [new File([blob], name, {type: it.mime})]});
    } catch (e) {
      // The tap's permission can run out while a big item downloads; the
      // bytes are kept, so the next tap shares right away.
      if (e.name !== 'AbortError') toast('ready · tap again to share');
    }
  }
}
// A picture onto the clipboard where the browser lets a page do that (a
// secure page: localhost, or https). Over plain http, iPhones and Android
// keep the clipboard from pages, so the picture opens full screen, where
// holding it gives the phone's own Copy.
function copyImage(it) {
  if (window.isSecureContext && navigator.clipboard && navigator.clipboard.write && window.ClipboardItem) {
    const png = fetchItem(it).then(r => { if (!r.ok) throw new Error(r.status); return r.blob(); }).then(toPng);
    navigator.clipboard.write([new ClipboardItem({'image/png': png})])
      .then(() => { toast('image copied'); mark(it, 'copied'); }, () => show(it, 'copy'));
    return;
  }
  show(it, 'copy');
}
async function toPng(blob) {
  if (blob.type === 'image/png') return blob;
  const bmp = await createImageBitmap(blob), c = document.createElement('canvas');
  c.width = bmp.width;
  c.height = bmp.height;
  c.getContext('2d').drawImage(bmp, 0, 0);
  return new Promise((ok, no) => c.toBlob(b => b ? ok(b) : no(new Error('png')), 'image/png'));
}
// On a phone a picture goes to Photos by holding it full screen (a
// download lands in Files instead, a button away there); the rest download.
function save(it) {
  if (isImage(it) && touch) return show(it, 'save');
  download(it);
  mark(it, 'saved');
}
// The desktop answers once it has the bytes itself, so an answer, or a
// failure, ends its copying.
async function fetchItem(it) {
  try { return await fetch(url(it)); } finally { asked.delete(it.key); tick(); }
}
async function fetchBlob(it) {
  const r = await fetchItem(it);
  if (!r.ok) throw new Error(r.status);
  if (!r.body) return r.blob();
  const bar = list.querySelector('[data-key="' + CSS.escape(it.key) + '"] .bar');
  const total = +r.headers.get('content-length') || it.size, reader = r.body.getReader(), chunks = [];
  let got = 0;
  if (bar) bar.classList.add('live');
  try {
    for (;;) {
      const {done, value} = await reader.read();
      if (done) break;
      chunks.push(value);
      got += value.length;
      if (bar && total) bar.firstChild.style.width = got / total * 100 + '%';
    }
  } finally {
    if (bar) bar.classList.remove('live');
  }
  return new Blob(chunks, {type: it.mime});
}
// A link with the download attribute, which the browser saves: Safari
// asks first, then it is in Files › Downloads. A home-screen app on an
// iPhone or iPad can't: the download takes over its only page, as a
// preview with no way back to the shelf. There the file opens in Safari's
// sheet over the app instead, from another of this shelf's addresses (a
// link to its own opens in the app), with Share › Save to Files, and ✕.
function download(it) {
  if (standalone && ios && OTHERS.length) {
    toast('share › save to files, then ✕');
    const a = document.createElement('a');
    a.href = (other || OTHERS[0]) + url(it) + '/' + encodeURIComponent(fileName(it));
    a.target = '_blank';
    document.body.appendChild(a);
    a.click();
    a.remove();
    return;
  }
  const a = document.createElement('a');
  a.href = url(it);
  a.download = fileName(it);
  document.body.appendChild(a);
  a.click();
  a.remove();
}
// Full screen, where holding the picture gives the phone's own menu:
// Copy, Save to Photos, Share. The line under it says which to pick.
function show(it, why) {
  viewing = it;
  $('pic').src = url(it);
  $('how').innerHTML = touch
    ? 'hold the picture, then tap <b>' + (why === 'save' ? 'Save to Photos' : 'Copy') + '</b>'
    : 'right-click the picture › <b>' + (why === 'save' ? 'Save Image' : 'Copy Image') + '</b>';
  view.classList.add('on');
}
function closeView() { view.classList.remove('on'); $('pic').removeAttribute('src'); viewing = null; }
$('close').onclick = closeView;
$('dl').onclick = () => { if (viewing) { download(viewing); mark(viewing, 'saved'); } };

// Copies inside the tap when the text came with the list; the clipboard
// API, where a browser gives it to a plain http page, and execCommand,
// which the rest take only from inside a user gesture.
function copyNow(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(() => toast('copied'), () => copyLegacy(text) ? toast('copied') : showSheet(text, true));
    return;
  }
  copyLegacy(text) ? toast('copied') : showSheet(text, true);
}
function copyLegacy(text) {
  const el = document.createElement('textarea');
  el.value = text;
  el.setAttribute('readonly', '');
  el.style.cssText = 'position:fixed;top:0;left:0;opacity:0;font-size:16px';
  document.body.appendChild(el);
  el.focus();
  el.select();
  el.setSelectionRange(0, text.length);
  let ok = false;
  try { ok = document.execCommand('copy'); } catch (e) {}
  el.remove();
  return ok;
}
async function copyText(it) {
  done.set(it.key, 'copied');
  if (typeof it.text === 'string') return copyNow(it.text);
  try {
    const r = await fetchItem(it);
    if (!r.ok) throw new Error(r.status);
    copyNow(await r.text());
  } catch (e) {
    toast("couldn't fetch that");
  }
}

// ------------------------------------------------------------- adding

$('add').onclick = () => $('file').click();
$('photo').onclick = () => $('pics').click();
// Straight to the phone's camera; a computer without one offers its files.
$('camera').onclick = () => $('shot').click();
for (const id of ['file', 'pics', 'shot']) $(id).onchange = () => { for (const f of $(id).files) upload(f); $(id).value = ''; };
addEventListener('dragover', e => e.preventDefault());
addEventListener('drop', e => { e.preventDefault(); for (const f of e.dataTransfer.files) upload(f); });
addEventListener('paste', e => {
  if (sheet.classList.contains('on')) return;
  const files = [...e.clipboardData.files];
  if (files.length) { e.preventDefault(); files.forEach(upload); return; }
  const t = e.clipboardData.getData('text');
  if (t.trim()) { e.preventDefault(); sendText(t); }
});
addEventListener('keydown', e => { if (e.key === 'Escape') { closeSheet(); closeView(); } });

// Two at a time from this page: the desktop takes four uploads at once
// from everyone and answers 503 past that, which is waited out; a
// connection that broke (how a refusal can look to a page still sending)
// is tried again a few times. The row says it waits meanwhile.
const waiting = [];
let sending = 0;
function upload(file) {
  const u = {id: ++seq, name: clean(file.name).trim() || 'file', size: file.size, pct: 0, file, tries: 0, busy: 0, wait: true};
  uploads.push(u);
  waiting.push(u);
  render();
  next();
}
function next() {
  while (sending < 2 && waiting.length) send(waiting.shift());
}
const refusal = (status, name) =>
  status === 413 ? name + ' is too big' : status === 507 ? 'no room for ' + name + ' right now' : "couldn't upload " + name;
// XHR rather than fetch: only XHR reports upload progress.
function send(u) {
  sending++;
  u.wait = false;
  u.pct = 0;
  render();
  const x = new XMLHttpRequest();
  x.open('POST', '/web/items?name=' + encodeURIComponent(u.name));
  x.setRequestHeader('x-plop-web', '1');
  x.upload.onprogress = e => {
    if (!e.lengthComputable) return;
    u.pct = Math.round(e.loaded / e.total * 100);
    const el = list.querySelector('[data-up="' + u.id + '"]');
    if (el) {
      el.querySelector('.time').textContent = u.pct + '%';
      el.querySelector('.bar i').style.width = u.pct + '%';
    }
  };
  const end = () => { sending--; next(); };
  // A 503 means the desktop took nothing and is busy with other uploads,
  // so that waits as long as it takes; a broken connection gets 3 tries.
  const retry = busy => {
    if (busy ? ++u.busy > 150 : ++u.tries > 3) return false;
    u.wait = true;
    render();
    setTimeout(() => { waiting.unshift(u); next(); }, busy ? Math.min(2000 * u.busy, 8000) : 2000 * u.tries);
    return true;
  };
  const done = () => { uploads = uploads.filter(v => v !== u); render(); };
  x.onload = () => {
    end();
    if (x.status === 503 && retry(true)) return;
    done();
    if (x.status !== 200) return toast(refusal(x.status, u.name));
    try { keep(JSON.parse(x.responseText)); } catch (e) {}
    poll();
  };
  x.onerror = () => { end(); if (retry(false)) return; done(); toast("couldn't upload " + u.name); };
  x.send(u.file);
}
async function sendText(t) {
  if (!t.trim()) return;
  closeSheet();
  try {
    let r;
    for (let i = 0; ; i++) {
      r = await fetch('/web/text', {method: 'POST', headers: {'content-type': 'text/plain;charset=utf-8', 'x-plop-web': '1'}, body: t});
      if (r.status !== 503 || i >= 3) break;
      await new Promise(ok => setTimeout(ok, 2000 * (i + 1)));
    }
    if (!r.ok) return toast(r.status === 507 ? 'no room for that right now' : "couldn't send that");
    keep(await r.json());
    poll();
  } catch (e) {
    toast("couldn't send that");
  }
}
function keep(up) {
  mine.set(up.key, {at: Date.now(), token: up.token});
  saveMine();
}
async function remove(key) {
  const m = mine.get(key);
  if (!m) return;
  const r = await fetch('/web/items/' + key, {method: 'DELETE', headers: {'x-plop-web': '1', 'x-plop-token': m.token}}).catch(() => null);
  if (!r || !r.ok) return toast("couldn't remove that");
  mine.delete(key);
  saveMine();
  items = items.filter(i => i.key !== key);
  seen.delete(key);
  render();
  poll();
}

// The clipboard is read where the browser allows (it asks first); the
// sheet is for everywhere else. In the sheet a paste plops at once, as the
// button says; typed text waits for "plop".
function showSheet(text, readonly) {
  ta.value = text || '';
  ta.readOnly = !!readonly;
  sheet.classList.toggle('show', !!readonly);
  $('cancel').textContent = readonly ? 'done' : 'cancel';
  sheet.classList.add('on');
  ta.focus();
  if (readonly) ta.select();
}
function closeSheet() { sheet.classList.remove('on'); ta.value = ''; }
$('cancel').onclick = closeSheet;
sheet.onclick = e => { if (e.target === sheet) closeSheet(); };
$('textform').onsubmit = e => { e.preventDefault(); if (!ta.readOnly) sendText(ta.value); };
ta.addEventListener('paste', () => {
  if (ta.readOnly || ta.value) return;
  setTimeout(() => sendText(ta.value), 0);
});
// Without the API (any plain-http page) the sheet opens inside the tap
// itself: iOS raises the keyboard only for a focus() made there.
$('paste').onclick = () => {
  if (!navigator.clipboard || !navigator.clipboard.readText) return showSheet('');
  navigator.clipboard.readText().then(t => t && t.trim() ? sendText(t) : showSheet(''), () => showSheet(''));
};

// ------------------------------------------------------------- home screen

const ios = /iP(hone|ad|od)/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
const standalone = navigator.standalone || matchMedia('(display-mode: standalone)').matches;
const touch = matchMedia('(pointer: coarse)').matches;
if (ios && !standalone && !store.get('plop.hint')) $('hint').classList.add('on');
$('hintx').onclick = () => { $('hint').classList.remove('on'); store.set('plop.hint', '1'); };
let installEvt;
addEventListener('beforeinstallprompt', e => { e.preventDefault(); installEvt = e; $('install').hidden = false; });
$('install').onclick = () => { if (installEvt) installEvt.prompt(); installEvt = null; $('install').hidden = true; };

render();
poll();
</script>
</body>
</html>
''';
