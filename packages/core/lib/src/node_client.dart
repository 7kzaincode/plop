import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'item.dart';
import 'node_server.dart';

/// Talks to other nodes' [NodeServer]s.
class NodeClient {
  final _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    ..idleTimeout = const Duration(seconds: 10);

  static const _listTimeout = Duration(seconds: 5);

  /// [selfId] tells the peer who is asking, so it can tell that this node
  /// can reach it.
  Future<List<RemoteItem>> fetchList(Uri base, String selfId) async {
    final req = await _http.getUrl(base.replace(path: '/v1/items'));
    req.headers.set(nodeIdHeader, selfId);
    final res = await req.close().timeout(_listTimeout);
    if (res.statusCode != HttpStatus.ok) {
      await res.drain<void>();
      throw HttpException('list failed: ${res.statusCode}', uri: base);
    }
    final body = await utf8.decodeStream(res).timeout(_listTimeout);
    return [
      for (final j in jsonDecode(body) as List)
        RemoteItem.fromJson(j as Map<String, dynamic>),
    ];
  }

  /// Streams an item into [destPath]. Writes to a `.part` file and renames on
  /// success, so a half-written file is never mistaken for a complete one.
  /// On any failure, a full disk or a failed rename included, the `.part`
  /// file is deleted.
  Future<void> download(
    Uri base,
    String id,
    String destPath, {
    required int expectedSize,
    void Function(int received)? onProgress,
  }) async {
    // Opened before asking, so a local error never strands a response.
    final part = File('$destPath.part');
    await part.parent.create(recursive: true);
    final out = await part.open(mode: FileMode.write);
    var received = 0;
    var closed = false, ok = false;
    try {
      final req = await _http.getUrl(base.replace(path: '/v1/items/$id'));
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>();
        throw HttpException('download failed: ${res.statusCode}', uri: base);
      }
      // A stalled sender (e.g. an iOS app that got suspended) should fail the
      // download rather than hang it forever.
      await for (final chunk in res.timeout(const Duration(seconds: 15))) {
        received += chunk.length;
        if (received > expectedSize) {
          throw HttpException('more bytes than advertised', uri: base);
        }
        // Awaited, unlike an IOSink: a full disk fails here and stops the
        // transfer, and a slow disk slows the sender.
        await out.writeFrom(chunk);
        onProgress?.call(received);
      }
      if (received != expectedSize) {
        throw HttpException(
          'short download: $received/$expectedSize',
          uri: base,
        );
      }
      await out.close();
      closed = true;
      await part.rename(destPath);
      ok = true;
    } finally {
      if (!closed) {
        // Failing anyway; the error already in flight is the one to report.
        try {
          await out.close();
        } catch (_) {}
      }
      if (!ok) await part.delete().catchError((_) => part);
    }
  }

  /// Tells a peer our list changed. Best effort: failures are ignored because
  /// the peer also polls.
  Future<void> nudge(Uri base, String selfId) async {
    try {
      final req = await _http.postUrl(base.replace(path: '/v1/changed'));
      req.headers.set(nodeIdHeader, selfId);
      final res = await req.close().timeout(const Duration(seconds: 3));
      await res.drain<void>();
    } catch (_) {}
  }

  void close() => _http.close(force: true);
}
