import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'item.dart';
import 'shelf_store.dart';
import 'web_host.dart';

/// Header a node sets on its requests so the receiver knows which peer is
/// talking to it.
const nodeIdHeader = 'x-plop-node';

/// Whether a request's Host header names this machine the way something on
/// the LAN does: an IP literal (IPv6 in brackets, as every client writes
/// it), `localhost` or a name under it, or an mDNS `.local` name; a port
/// may follow. Peers always connect by IP. Anything else is a page out on
/// the web that pointed its own name at this machine's address (DNS
/// rebinding), which browsers then let it read and write as its own: the
/// web shelf's fixed port makes this machine easy to find. No Host at all
/// is fine; no browser sends that.
bool isLanHost(String? host) {
  if (host == null) return true;
  var h = host.trim().toLowerCase();
  if (h.startsWith('[')) {
    final end = h.indexOf(']');
    if (end < 0) return false;
    final rest = h.substring(end + 1);
    if (rest.isNotEmpty && !_portSuffix.hasMatch(rest)) return false;
    // A zone id (`%en0`, or `%25en0` as URLs write it) only says which
    // interface a link-local address is on, and never makes an address
    // more local than it is. It is dropped before parsing, all of it:
    // tryParse refuses one that names an interface this machine lacks, so
    // what passed would depend on the machine.
    final ip = h.substring(1, end).replaceFirst(_zoneId, '');
    return InternetAddress.tryParse(ip)?.type == InternetAddressType.IPv6;
  }
  final colon = h.lastIndexOf(':');
  if (colon >= 0) {
    if (!_portSuffix.hasMatch(h.substring(colon))) return false;
    h = h.substring(0, colon);
  }
  if (h.endsWith('.')) h = h.substring(0, h.length - 1); // fully qualified
  if (h.isEmpty) return false;
  final ip = InternetAddress.tryParse(h);
  if (ip != null) return ip.type == InternetAddressType.IPv4;
  return h == 'localhost' || h.endsWith('.localhost') || h.endsWith('.local');
}

final _portSuffix = RegExp(r'^:[0-9]{1,5}$');
final _zoneId = RegExp(r'%.*$');

/// [req]'s body, for a reader that may stop early or never start. It is
/// claimed at once and paused: dart:io reads a body nobody has claimed to
/// its end before it lets any answer out, so a 413 for a 100 GB upload
/// would first take the 100 GB. Cancelling only pauses it as well: a
/// cancelled body destroys the connection on the spot, answer or no
/// answer, while a paused one goes with the connection once the answer is
/// out (a body left unread is never kept alive).
Stream<List<int>> claimBody(HttpRequest req) {
  final c = StreamController<List<int>>();
  final sub = req.listen(c.add, onError: c.addError, onDone: c.close)..pause();
  c
    ..onListen = sub.resume
    ..onPause = sub.pause
    ..onResume = sub.resume
    ..onCancel = sub.pause;
  return c.stream;
}

/// Serves this node's own items. Mirrors are never re-served.
class NodeServer {
  NodeServer(this.store, {this.onNudge});

  final ShelfStore store;

  /// Called on `POST /v1/changed` with the sender's node id, if it gave one.
  final void Function(String? fromId)? onNudge;

  /// Answers every path outside /v1 while it is enabled; 404 otherwise.
  WebHost? web;

  HttpServer? _server;

  /// When each peer last reached this node, by node id. A peer that we can
  /// reach but that never shows up here is being blocked by a firewall.
  final seenBy = <String, DateTime>{};

  int _port = 0;

  /// The port this node was last bound to. Unlike HttpServer.port it stays
  /// readable after the socket is closed, which is when a restart needs it.
  int get port => _port;

  Future<void> start({int port = 0}) async {
    try {
      // Dual-stack (v6Only is off by default): IPv4 peers still connect, and
      // the routable IPv6 addresses the app offers as fallbacks become
      // usable instead of each costing a connection timeout.
      _server = await HttpServer.bind(InternetAddress.anyIPv6, port);
    } on SocketException {
      // IPv6 is off on this host.
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    }
    _port = _server!.port;
    _server!.listen((req) => _handle(req).catchError((_) {}), onError: (_) {});
  }

  /// Re-binds after the OS reclaimed the socket (iOS does this while the app
  /// is suspended). Keeps the port when it can, so peers that still have the
  /// old address keep working.
  Future<void> restart() async {
    await _server?.close(force: true);
    try {
      await start(port: _port);
    } on SocketException {
      await start();
    }
  }

  /// The caller's node id, if it sent one that passes [isValidId]. Anything
  /// else is treated as no id: [seenBy] and an item's `receivedBy` grow by
  /// one entry per distinct value, so a hostile peer must not be able to
  /// supply an endless run of them.
  String? _callerId(HttpRequest req) {
    final from = req.headers.value(nodeIdHeader);
    return from != null && isValidId(from) ? from : null;
  }

  void _noteCaller(HttpRequest req) {
    final from = _callerId(req);
    if (from != null) seenBy[from] = DateTime.now();
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    // Before any route, /v1 included. Two Host headers are refused too:
    // which one a browser or a proxy acted on is anyone's guess.
    final host = req.headers[HttpHeaders.hostHeader];
    if (!(host == null || host.length == 1 && isLanHost(host.single))) {
      claimBody(req);
      res.statusCode = HttpStatus.misdirectedRequest;
      await res.close();
      return;
    }
    switch ((req.method, req.uri.pathSegments)) {
      case ('GET', ['v1', 'items']):
        _noteCaller(req);
        final items = <Map<String, Object>>[];
        for (final i in store.localItems.toList()) {
          // The list is a snapshot: remove() mutates, and an item can
          // expire while another's stat is in flight.
          if (i.isReady && await store.stillThere(i) && store[i.key] == i) {
            items.add(i.toJson());
          }
        }
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(items));
      case ('GET', ['v1', 'items', final id]):
        final item = store.local(id);
        final file = item?.path != null && await store.stillThere(item!)
            ? File(item.path!)
            : null;
        if (file == null || !await file.exists()) {
          res.statusCode = HttpStatus.notFound;
          break;
        }
        res.headers.contentType = ContentType.parse(item!.mime);
        res.contentLength = await file.length();
        await file.openRead().pipe(res);
        return; // pipe closes the response
      case ('POST', ['v1', 'items', final id, 'received']):
        await req.drain<void>();
        _noteCaller(req);
        res.statusCode = HttpStatus.noContent;
        final from = _callerId(req);
        final item = store.local(id);
        if (from != null && item != null) store.markReceived(item.key, from);
      case ('POST', ['v1', 'changed']):
        await req.drain<void>();
        _noteCaller(req);
        res.statusCode = HttpStatus.noContent;
        onNudge?.call(_callerId(req));
      default:
        if (web case final web? when web.enabled) return web.handle(req);
        res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  }

  Future<void> stop() async => _server?.close(force: true);
}
