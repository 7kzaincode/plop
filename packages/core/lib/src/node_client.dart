import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'circle.dart';
import 'item.dart';
import 'node_server.dart';
import 'private_link.dart';

/// A download that broke off part way through its body: the connection
/// dropped or was reset, or no byte came for the stall timeout. The sender
/// may well be fine, and asking again may work: this end may have been
/// the one that stopped, a phone that put the app in the background, say.
/// A refusal or a wrong size stays an [HttpException], and a download's
/// cut-off a [TimeoutException].
class TransferInterrupted implements Exception {
  const TransferInterrupted(this.cause);

  /// What dart:io said: an [HttpException], a [SocketException], or the
  /// stall's [TimeoutException].
  final Object cause;

  @override
  String toString() => 'transfer interrupted: $cause';
}

/// Talks to other nodes' [NodeServer]s.
class NodeClient {
  final _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3)
    ..idleTimeout = const Duration(seconds: 10);

  static const _listTimeout = Duration(seconds: 5);

  /// The circle whose key signs every request and opens every answer while
  /// private mode is on; null otherwise. Read once per request, so one
  /// that is running when it changes finishes under the key it began with.
  Circle? circle;

  /// Signs [req] for [selfId] when [under] or [circle] is set. Returns what opens the
  /// answer: the body as it came, or unsealed under the request's nonce.
  Stream<List<int>> Function(Stream<List<int>>) _sign(
    HttpClientRequest req,
    String selfId, [
    Circle? under,
  ]) {
    final c = under ?? circle;
    if (c == null) return (body) => body;
    final path = pathOf(req.uri);
    final (header, nonce) = signRequest(
      c.authKey,
      method: req.method,
      path: path,
      nodeId: selfId,
    );
    req.headers.set(authHeader, header);
    return (body) =>
        openStream(body, c.bodyKey, responseContext(nonce, req.method, path));
  }

  /// A list entry is ~150 bytes, so this is thousands of items. Every node
  /// polls every peer, so one that streams an endless list must not be
  /// allowed to fill the memory of every device around it.
  static const _maxListBytes = 1 << 20;

  /// [selfId] tells the peer who is asking, so it can tell that this node
  /// can reach it.
  Future<List<RemoteItem>> fetchList(Uri base, String selfId) async =>
      (await fetchShelf(base, selfId)).items;

  /// [fetchList], with the name a private node gives in its sealed list
  /// (it advertises none); null from a public node.
  Future<({List<RemoteItem> items, String? name})> fetchShelf(
    Uri base,
    String selfId,
  ) async {
    final req = await _http.getUrl(base.replace(path: '/v1/items'));
    req.headers.set(nodeIdHeader, selfId);
    final open = _sign(req, selfId);
    final res = await req.close().timeout(_listTimeout);
    if (res.statusCode != HttpStatus.ok) {
      await _hangUp(res);
      throw HttpException('list failed: ${res.statusCode}', uri: base);
    }
    // Throwing out of `await for` cancels the subscription and drops the
    // socket; Future.timeout on a decodeStream would leave it buffering.
    final buf = BytesBuilder(copy: false);
    await for (final chunk in open(res.timeout(_listTimeout))) {
      buf.add(chunk);
      if (buf.length > _maxListBytes) {
        throw HttpException('list too large', uri: base);
      }
    }
    // A private node's list is {"name": …, "items": […]}.
    final body = jsonDecode(utf8.decode(buf.takeBytes()));
    final list = body is Map ? body['items'] as List : body as List;
    final name = body is Map ? body['name'] : null;
    return (
      items: [
        for (final j in list) RemoteItem.fromJson(j as Map<String, dynamic>),
      ],
      name: name is String ? name : null,
    );
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
  /// file is deleted. A body that breaks off fails with a
  /// [TransferInterrupted]. If [cutOff] completes first, the download is
  /// dropped with a [TimeoutException], however the sender paces its bytes.
  Future<void> download(
    Uri base,
    String id,
    String destPath, {
    required int expectedSize,
    void Function(int received)? onProgress,
    Future<void>? cutOff,
    String selfId = '',
  }) async {
    // Opened before asking, so a local error never strands a response.
    final part = File('$destPath.part');
    await part.parent.create(recursive: true);
    final out = await part.open(mode: FileMode.write);
    var received = 0;
    var closed = false, ok = false;
    try {
      final req = await _http.getUrl(base.replace(path: '/v1/items/$id'));
      if (selfId.isNotEmpty) req.headers.set(nodeIdHeader, selfId);
      final open = _sign(req, selfId);
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
      // Whatever breaks the body (the stall, a hang-up, a reset) is an
      // interruption, told apart from what this end decides below (too
      // many bytes, too few) and from [cutOff], added after.
      // Private mode unseals after the interruption check, so a body that
      // broke off is still an interruption, while one that was tampered
      // with fails with a PrivateLinkException.
      var body = open(
        res
            .timeout(const Duration(seconds: 15))
            .handleError((Object e) => throw TransferInterrupted(e)),
      );
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
      _sign(req, selfId);
      final res = await req.close().timeout(const Duration(seconds: 3));
      await res.drain<void>();
    } catch (_) {}
  }

  /// Most a pairing or circle answer may be; they are a few hundred bytes.
  static const _maxJsonBytes = 64 << 10;

  /// Posts [body] as JSON to a pairing route ([path] under /v1/pair), which
  /// is not signed: the two devices share nothing yet. Returns the status
  /// and the JSON answer, if there was one.
  Future<(int, Map<String, Object?>?)> pairPost(
    Uri base,
    String path,
    Map<String, Object?> body,
  ) async {
    final req = await _http.postUrl(base.replace(path: path));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final res = await req.close().timeout(const Duration(seconds: 5));
    return (res.statusCode, await _json(res, (b) => b));
  }

  /// Asks a peer, signed with [c], which device it is: its public key and
  /// the epoch of its circle. Null if it does not answer as a member of
  /// [c] would.
  Future<Map<String, Object?>?> circleInfo(
    Uri base,
    String selfId,
    Circle c,
  ) async {
    try {
      final req = await _http.getUrl(base.replace(path: '/v1/circle'));
      req.headers.set(nodeIdHeader, selfId);
      final open = _sign(req, selfId, c);
      final res = await req.close().timeout(const Duration(seconds: 3));
      if (res.statusCode != HttpStatus.ok) {
        await _hangUp(res);
        return null;
      }
      return await _json(res, open);
    } catch (_) {
      return null;
    }
  }

  /// Posts [body] to a circle route, signed with [c]; the status, or null
  /// if the peer could not be reached.
  Future<int?> circlePost(
    Uri base,
    String path,
    String selfId,
    Circle c,
    Map<String, Object?> body,
  ) async {
    try {
      final req = await _http.postUrl(base.replace(path: path));
      req.headers
        ..set(nodeIdHeader, selfId)
        ..contentType = ContentType.json;
      _sign(req, selfId, c);
      req.write(jsonEncode(body));
      final res = await req.close().timeout(const Duration(seconds: 3));
      await _hangUp(res);
      return res.statusCode;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, Object?>?> _json(
    HttpClientResponse res,
    Stream<List<int>> Function(Stream<List<int>>) open,
  ) async {
    final buf = BytesBuilder(copy: false);
    await for (final chunk in open(res.timeout(const Duration(seconds: 5)))) {
      buf.add(chunk);
      if (buf.length > _maxJsonBytes) throw const FormatException('too big');
    }
    if (buf.isEmpty) return null;
    try {
      return (jsonDecode(utf8.decode(buf.takeBytes())) as Map).cast();
    } catch (_) {
      return null;
    }
  }

  void close() => _http.close(force: true);
}
