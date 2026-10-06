import 'dart:convert';
import 'dart:io';

import 'shelf_store.dart';

/// Header a node sets on its requests so the receiver knows which peer is
/// talking to it.
const nodeIdHeader = 'x-plop-node';

/// Serves this node's own items. Mirrors are never re-served.
class NodeServer {
  NodeServer(this.store, {this.onNudge});

  final ShelfStore store;

  /// Called on `POST /v1/changed` with the sender's node id, if it gave one.
  final void Function(String? fromId)? onNudge;

  HttpServer? _server;

  /// When each peer last reached this node, by node id. A peer that we can
  /// reach but that never shows up here is being blocked by a firewall.
  final seenBy = <String, DateTime>{};

  int _port = 0;

  /// The port this node was last bound to. Unlike HttpServer.port it stays
  /// readable after the socket is closed, which is when a restart needs it.
  int get port => _port;

  Future<void> start({int port = 0}) async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
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

  void _noteCaller(HttpRequest req) {
    final from = req.headers.value(nodeIdHeader);
    if (from != null) seenBy[from] = DateTime.now();
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    switch ((req.method, req.uri.pathSegments)) {
      case ('GET', ['v1', 'items']):
        _noteCaller(req);
        final items = [
          for (final i in store.localItems)
            if (i.isReady) i.toJson(),
        ];
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(items));
      case ('GET', ['v1', 'items', final id]):
        final item = store.local(id);
        final file = item?.path == null ? null : File(item!.path!);
        if (file == null || !await file.exists()) {
          res.statusCode = HttpStatus.notFound;
          break;
        }
        res.headers.contentType = ContentType.parse(item!.mime);
        res.contentLength = await file.length();
        await file.openRead().pipe(res);
        return; // pipe closes the response
      case ('POST', ['v1', 'changed']):
        await req.drain<void>();
        _noteCaller(req);
        res.statusCode = HttpStatus.noContent;
        onNudge?.call(req.headers.value(nodeIdHeader));
      default:
        res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  }

  Future<void> stop() async => _server?.close(force: true);
}
