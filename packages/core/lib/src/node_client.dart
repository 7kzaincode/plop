import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'item.dart';
import 'node_server.dart';

/// Talks to other nodes' [NodeServer]s.
class NodeClient {
  final _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    ..idleTimeout = const Duration(seconds: 10);

  static const _listTimeout = Duration(seconds: 5);

  /// A list entry is ~150 bytes, so this is thousands of items. Every node
  /// polls every peer, so one that streams an endless list must not be
  /// allowed to fill the memory of every device around it.
  static const _maxListBytes = 1 << 20;

  /// [selfId] tells the peer who is asking, so it can tell that this node
  /// can reach it.
  Future<List<RemoteItem>> fetchList(Uri base, String selfId) async {
    final req = await _http.getUrl(base.replace(path: '/v1/items'));
    req.headers.set(nodeIdHeader, selfId);
    final res = await req.close().timeout(_listTimeout);
    if (res.statusCode != HttpStatus.ok) {
      await _hangUp(res);
      throw HttpException('list failed: ${res.statusCode}', uri: base);
    }
    // Throwing out of `await for` cancels the subscription and drops the
    // socket; Future.timeout on a decodeStream would leave it buffering.
    final buf = BytesBuilder(copy: false);
    await for (final chunk in res.timeout(_listTimeout)) {
      buf.add(chunk);
      if (buf.length > _maxListBytes) {
        throw HttpException('list too large', uri: base);
      }
    }
    return [
      for (final j in jsonDecode(utf8.decode(buf.takeBytes())) as List)
        RemoteItem.fromJson(j as Map<String, dynamic>),
    ];
  }

  /// Drops a response whose body is not wanted. Not `drain()`: that reads
  /// the body to its end, and a timeout on it gives up waiting without
  /// stopping the read, so a peer answering with an endless body would hold
  /// the socket for good. Cancelling the subscription destroys the
  /// connection instead; the pool loses one, which is nothing.
  static Future<void> _hangUp(HttpClientResponse res) =>
      res.listen(null).cancel();

  static TimeoutException get _outOfTime =>
      TimeoutException('download ran out of time');

  /// [body], failing with [_outOfTime] once [cutOff] completes. The
  /// subscription to [body] is cancelled then, which, as in [_hangUp],
  /// drops the connection.
  static Stream<List<int>> _until(Stream<List<int>> body, Future<void> cutOff) {
    final out = StreamController<List<int>>();
    StreamSubscription<List<int>>? sub;
    out
      ..onListen = () {
        sub = body.listen(out.add, onError: out.addError, onDone: out.close);
        cutOff.then((_) {
          if (out.isClosed) return;
          out
            ..addError(_outOfTime)
            ..close();
        });
      }
      ..onPause = (() => sub?.pause())
      ..onResume = (() => sub?.resume())
      ..onCancel = (() => sub?.cancel());
    return out.stream;
  }

  /// Streams an item into [destPath]. Writes to a `.part` file and renames on
  /// success, so a half-written file is never mistaken for a complete one.
  /// On any failure, a full disk or a failed rename included, the `.part`
  /// file is deleted. If [cutOff] completes first, the download is dropped
  /// with a [TimeoutException], however the sender paces its bytes.
  Future<void> download(
    Uri base,
    String id,
    String destPath, {
    required int expectedSize,
    void Function(int received)? onProgress,
    Future<void>? cutOff,
  }) async {
    // Opened before asking, so a local error never strands a response.
    final part = File('$destPath.part');
    await part.parent.create(recursive: true);
    final out = await part.open(mode: FileMode.write);
    var received = 0;
    var closed = false, ok = false;
    try {
      final req = await _http.getUrl(base.replace(path: '/v1/items/$id'));
      // While waiting for the headers; once they are in, abort() does
      // nothing, and [_until] takes over.
      cutOff?.then((_) => req.abort(_outOfTime));
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != HttpStatus.ok) {
        await _hangUp(res);
        throw HttpException('download failed: ${res.statusCode}', uri: base);
      }
      // A stalled sender (e.g. an iOS app that got suspended) should fail the
      // download rather than hang it forever. That only catches a sender
      // that stops, not one that sends a byte now and then: [cutOff] does.
      var body = res.timeout(const Duration(seconds: 15));
      if (cutOff != null) body = _until(body, cutOff);
      await for (final chunk in body) {
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
  Future<void> nudge(Uri base, String selfId) =>
      _post(base, '/v1/changed', selfId);

  /// Tells an item's origin that this node holds a complete copy of it, so
  /// the sender can see it arrived. Best effort too. The origin cannot tell
  /// this itself: dart:io hides a peer hanging up mid-response from the
  /// server, so only the receiver knows the transfer finished.
  Future<void> confirmReceived(Uri base, String id, String selfId) =>
      _post(base, '/v1/items/$id/received', selfId);

  Future<void> _post(Uri base, String path, String selfId) async {
    try {
      final req = await _http.postUrl(base.replace(path: path));
      req.headers.set(nodeIdHeader, selfId);
      final res = await req.close().timeout(const Duration(seconds: 3));
      await res.drain<void>();
    } catch (_) {}
  }

  void close() => _http.close(force: true);
}
