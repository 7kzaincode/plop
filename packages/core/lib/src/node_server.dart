import 'dart:convert';
import 'dart:io';

import 'item.dart';
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

  /// When each peer last reached this node, by node id, least recent
  /// first. A peer that we can reach but that never shows up here is being
  /// blocked by a firewall. At most [maxSeenBy] entries.
  final seenBy = <String, DateTime>{};

  /// Most callers [seenBy] remembers; past it, the one heard from longest
  /// ago is let go. A real peer polls every 3 s, so it is never that one
  /// unless something is inventing ids by the hundred.
  static const maxSeenBy = 256;

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

  /// The caller's node id, if it sent one that passes [isValidId], which
  /// makes it safe as a map key and a path segment; anything else is
  /// treated as no id. The check says nothing about how many there are: a
  /// hostile peer can make up a fresh id for every request, so [seenBy] and
  /// an item's `receivedBy` are capped rather than trusted to stay small.
  String? _callerId(HttpRequest req) {
    final from = req.headers.value(nodeIdHeader);
    return from != null && isValidId(from) ? from : null;
  }

  void _noteCaller(HttpRequest req) {
    final from = _callerId(req);
    if (from == null) return;
    seenBy.remove(from); // to the end, so the first is the least recent
    seenBy[from] = DateTime.now();
    if (seenBy.length > maxSeenBy) seenBy.remove(seenBy.keys.first);
  }

  /// How long a list waits on any one file's check. A stat on a dead mount
  /// can hang for a minute; the list must still answer well inside a
  /// peer's 5 s timeout, or every peer drops this node and its items, and
  /// inside the 1 s probe of `PlopNode.revive`, or the server is restarted
  /// under its transfers.
  static const statBudget = Duration(milliseconds: 500);

  /// Checks of files served in place that are still running, by item key,
  /// so a hung stat is shared by every poll from every peer rather than
  /// joined by one more each time.
  final _checks = <String, Future<bool>>{};

  /// A file served in place can be deleted or rewritten after it was
  /// dropped. Listing it then leaves every peer a row it can never fetch,
  /// so instead it leaves the shelf, which nudges them to drop theirs.
  /// Asynchronous because this runs on every poll from every peer, and a
  /// stat of a file on an unmounted share or a cloud placeholder can hang
  /// for seconds; a synchronous one would stall the whole isolate with it.
  Future<bool> _stillThere(ShelfItem i) {
    if (i.ownsFile || i.path == null) return Future.value(true);
    // The callback must not return the removed future: whenComplete would
    // wait on it, and it is the future being completed.
    return _checks[i.key] ??= _check(i).whenComplete(() {
      _checks.remove(i.key);
    });
  }

  Future<bool> _check(ShelfItem i) async {
    final st = await File(i.path!).stat();
    // Size alone misses a rewrite that keeps it, so the modification time
    // counts too; a store that never recorded one only has the size.
    if (st.type != FileSystemEntityType.notFound &&
        st.size == i.size &&
        (i.sourceModified == null || st.modified == i.sourceModified)) {
      return true;
    }
    store.remove(i.key);
    return false;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    switch ((req.method, req.uri.pathSegments)) {
      case ('GET', ['v1', 'items']):
        _noteCaller(req);
        // A snapshot: remove() mutates, and an item can expire while a
        // stat is in flight.
        final ready = [
          for (final i in store.localItems)
            if (i.isReady) i,
        ];
        // All at once, each within [statBudget]. One that runs over lists
        // its item: calling it gone would make every peer drop the row and
        // add it back on the next poll. If the stat does come back with the
        // file gone, the item still leaves then, and peers are nudged.
        final present = await Future.wait([
          for (final i in ready)
            _stillThere(i).timeout(statBudget, onTimeout: () => true),
        ]);
        final items = [
          for (final (n, i) in ready.indexed)
            if (present[n] && store[i.key] == i) i.toJson(),
        ];
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(items));
      case ('GET', ['v1', 'items', final id]):
        final item = store.local(id);
        final file = item?.path != null && await _stillThere(item!)
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
        res.statusCode = HttpStatus.notFound;
    }
    await res.close();
  }

  Future<void> stop() async => _server?.close(force: true);
}
