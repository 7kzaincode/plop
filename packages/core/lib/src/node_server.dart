import 'dart:convert';
import 'dart:io';

import 'shelf_store.dart';

/// Header a node sets on `POST /v1/changed` so the receiver knows which peer
/// to re-fetch.
const nodeIdHeader = 'x-plop-node';

/// Serves this node's own items. Mirrors are never re-served.
class NodeServer {
  NodeServer(this.store, {this.onNudge});

  final ShelfStore store;

  /// Called on `POST /v1/changed` with the sender's node id, if it gave one.
  final void Function(String? fromId)? onNudge;

  HttpServer? _server;

  int get port => _server!.port;

  Future<void> start({int port = 0}) async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen((req) => _handle(req).catchError((_) {}));
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    switch ((req.method, req.uri.pathSegments)) {
      case ('GET', ['v1', 'items']):
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
        res.statusCode = HttpStatus.noContent;
        onNudge?.call(req.headers.value(nodeIdHeader));
      default:
        res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  }

  Future<void> stop() async => _server?.close(force: true);
}
