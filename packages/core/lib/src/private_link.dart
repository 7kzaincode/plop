import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart'
    show MacAlgorithm, SecretKeyData;
import 'package:cryptography/dart.dart' show DartChacha20;

// The secure link private mode runs over: request signatures, sealed
// streams and one-shot sealed boxes. Nothing here knows about HTTP servers,
// sockets or the LAN: it signs a method and a path and seals bytes, so a
// relay ("anywhere" mode, later) can carry the same headers and bodies
// unchanged. See docs/PROTOCOL.md, "Private mode".
//
// All of it is pure Dart, from package:cryptography (ChaCha20) and
// package:crypto (SHA-256, HMAC), so it costs no native plugin on any
// platform. Bodies are ChaCha20 then HMAC-SHA256 over the ciphertext
// (encrypt-then-MAC) rather than ChaCha20-Poly1305: the pure-Dart Poly1305
// runs at under 40 MB/s, HMAC-SHA256 near three times that, and a large
// file should cross a fast LAN at close to the speed it would in the clear.

/// Something about a signed request or a sealed body did not check out:
/// a wrong key, a changed byte, a body cut short, a stale or replayed
/// signature. Never says which key or byte, on purpose.
class PrivateLinkException implements Exception {
  const PrivateLinkException(this.message);
  final String message;

  @override
  String toString() => 'private link: $message';
}

final _random = Random.secure();

/// [n] bytes from the OS's secure random source.
Uint8List randomBytes(int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = _random.nextInt(256);
  }
  return b;
}

Uint8List sha256Of(List<int> bytes) =>
    Uint8List.fromList(crypto.sha256.convert(bytes).bytes);

Uint8List hmacSha256(List<int> key, List<int> bytes) =>
    Uint8List.fromList(crypto.Hmac(crypto.sha256, key).convert(bytes).bytes);

/// HKDF-SHA256 (RFC 5869): [length] bytes from [ikm], with [salt] (none
/// means zeros) and [info] saying what they are for. Synchronous, unlike
/// package:cryptography's, so a key can be worked out where it is needed;
/// the test suite checks it against that one.
Uint8List hkdf(
  List<int> ikm, {
  List<int> salt = const [],
  required List<int> info,
  int length = 32,
}) {
  final prk = hmacSha256(salt.isEmpty ? Uint8List(32) : salt, ikm);
  final out = BytesBuilder(copy: false);
  var t = const <int>[];
  for (var i = 1; out.length < length; i++) {
    t = hmacSha256(prk, [...t, ...info, i]);
    out.add(t);
  }
  return Uint8List.sublistView(out.takeBytes(), 0, length);
}

/// Compares in time that does not depend on where they first differ, so a
/// forger cannot find a tag a byte at a time.
bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

String hexOf(List<int> b) =>
    [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

/// URL-safe base64 without padding, how keys travel in JSON and headers.
String b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

/// Throws a [FormatException] for anything that is not [b64].
Uint8List unb64(String s) => base64Url.decode(base64Url.normalize(s));

Uint8List _utf8(String s) => utf8.encode(s);

// ---------------------------------------------------------------------------
// Frames: one sealed piece of bytes.

const _tagLength = 32;
final _chacha = DartChacha20(macAlgorithm: MacAlgorithm.empty);

/// ChaCha20 under [encKey] and [nonce], then HMAC-SHA256 under [macKey]
/// over the nonce, [aad] and the ciphertext. Returns ciphertext then tag.
/// [nonce] must never repeat under one key: every caller derives a fresh
/// key per stream or box, and counts frames within it.
Uint8List _seal(
  Uint8List encKey,
  Uint8List macKey,
  Uint8List nonce,
  List<int> aad,
  List<int> plain,
) {
  final ct = _chacha
      .encryptSync(plain, secretKey: SecretKeyData(encKey), nonce: nonce)
      .cipherText;
  final out = Uint8List(ct.length + _tagLength)..setAll(0, ct);
  out.setAll(ct.length, _tag(macKey, nonce, aad, ct));
  return out;
}

List<int> _tag(Uint8List macKey, Uint8List nonce, List<int> aad, List<int> ct) {
  final result = _Sink();
  final mac = crypto.Hmac(crypto.sha256, macKey).startChunkedConversion(result)
    ..add(nonce)
    ..add(_u32(aad.length))
    ..add(aad)
    ..add(ct);
  mac.close();
  return result.value!.bytes;
}

/// The opposite of [_seal]; throws [PrivateLinkException] if the tag does
/// not match, before anything is decrypted.
Uint8List _open(
  Uint8List encKey,
  Uint8List macKey,
  Uint8List nonce,
  List<int> aad,
  Uint8List sealed,
) {
  if (sealed.length < _tagLength) {
    throw const PrivateLinkException('frame too short');
  }
  final n = sealed.length - _tagLength;
  final ct = Uint8List.sublistView(sealed, 0, n);
  if (!sameBytes(_tag(macKey, nonce, aad, ct), sealed.sublist(n))) {
    throw const PrivateLinkException('frame does not authenticate');
  }
  // ChaCha20 is a keystream XOR: running it again decrypts. The tag is
  // checked above; the cipher has none of its own.
  return Uint8List.fromList(
    _chacha
        .encryptSync(ct, secretKey: SecretKeyData(encKey), nonce: nonce)
        .cipherText,
  );
}

class _Sink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest d) => value = d;
  @override
  void close() {}
}

Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

/// The two keys a frame needs, from one [key] and what it is for.
(Uint8List, Uint8List) _split(List<int> key, List<int> salt, List<int> info) {
  final okm = hkdf(key, salt: salt, info: info, length: 64);
  return (Uint8List.sublistView(okm, 0, 32), Uint8List.sublistView(okm, 32));
}

// ---------------------------------------------------------------------------
// Boxes: a small message sealed whole.

const _boxMagic = [0x50, 0x4c, 0x42, 0x31]; // "PLB1"

/// [plain] sealed under [key] for [context] (a label saying what it is, so
/// a box made for one purpose never opens as another). A fresh random salt
/// gives every box its own keys. Layout: "PLB1", 16-byte salt, ciphertext,
/// 32-byte tag.
Uint8List sealBox(List<int> key, String context, List<int> plain) {
  final salt = randomBytes(16);
  final (enc, mac) = _split(key, salt, _utf8('plop box v1\n$context'));
  final body = _seal(enc, mac, Uint8List(12), _boxMagic, plain);
  return Uint8List.fromList([..._boxMagic, ...salt, ...body]);
}

/// Opens a [sealBox]; throws [PrivateLinkException] if it is not one,
/// was made under another key or context, or was changed.
Uint8List openBox(List<int> key, String context, List<int> sealed) {
  if (sealed.length < 4 + 16 + _tagLength ||
      !sameBytes(sealed.sublist(0, 4), _boxMagic)) {
    throw const PrivateLinkException('not a sealed box');
  }
  final salt = sealed.sublist(4, 20);
  final (enc, mac) = _split(key, salt, _utf8('plop box v1\n$context'));
  return _open(
    enc,
    mac,
    Uint8List(12),
    _boxMagic,
    Uint8List.fromList(sealed.sublist(20)),
  );
}

// ---------------------------------------------------------------------------
// Streams: a body of any size, sealed in frames as it goes.

const _streamMagic = [0x50, 0x4c, 0x53, 0x31]; // "PLS1"
const _headerLength = 4 + 16;
const _final = 0x80000000;

/// Bytes of plaintext per frame. Large enough that the per-frame cost (a
/// key schedule, an HMAC finalisation, 36 bytes) vanishes; small enough
/// that a receiver holds little before it can check what it got.
const streamChunk = 64 << 10;

/// How many bytes [sealStream] makes of [plain] bytes: the header, and
/// one frame per [streamChunk] plus a final one (which may be empty). A
/// sender knows it before it starts, so a sealed file still goes out with
/// a Content-Length.
int sealedLength(int plain, {int chunk = streamChunk}) =>
    _headerLength + (plain ~/ chunk + 1) * (4 + _tagLength) + plain;

/// [plain] sealed under [key] for [context], frame by frame as it arrives,
/// so a file of any size streams through without being held in memory.
///
/// Layout: "PLS1", a random 16-byte salt (which with [key] and [context]
/// gives this stream its own cipher and MAC keys), then frames. A frame is
/// a 4-byte big-endian length (top bit set on the last frame), that many
/// bytes of ciphertext and a 32-byte tag over the frame's number, its
/// length word and the ciphertext. The number is in the tag, so frames
/// cannot be reordered, dropped or repeated; the last-frame bit is in it,
/// so a stream cannot be cut short at a frame boundary either.
Stream<List<int>> sealStream(
  Stream<List<int>> plain,
  List<int> key,
  String context, {
  int chunk = streamChunk,
}) async* {
  final salt = randomBytes(16);
  final (enc, mac) = _split(key, salt, _utf8('plop stream v1\n$context'));
  yield [..._streamMagic, ...salt];
  var n = 0;
  final buf = Uint8List(chunk);
  var filled = 0;
  Uint8List frame(int len, {required bool last}) {
    final word = _u32(len | (last ? _final : 0));
    final sealed = _seal(enc, mac, _nonce(n++), word, buf.sublist(0, len));
    return Uint8List(4 + sealed.length)
      ..setAll(0, word)
      ..setAll(4, sealed);
  }

  await for (final piece in plain) {
    var at = 0;
    while (at < piece.length) {
      final take = min(chunk - filled, piece.length - at);
      buf.setRange(filled, filled + take, piece, at);
      filled += take;
      at += take;
      if (filled == chunk) {
        yield frame(chunk, last: false);
        filled = 0;
      }
    }
  }
  yield frame(filled, last: true);
}

Uint8List _nonce(int n) => Uint8List(12)..buffer.asByteData().setUint64(4, n);

/// The plaintext of a [sealStream], frame by frame. Fails with a
/// [PrivateLinkException] at the first frame that does not check out, and
/// at the end if the last frame never came (a body cut short) or bytes
/// follow it; nothing from a frame is passed on before its tag is checked.
/// A frame longer than [chunk] is refused before it is read, so a hostile
/// sender cannot make the reader buffer much.
Stream<List<int>> openStream(
  Stream<List<int>> sealed,
  List<int> key,
  String context, {
  int chunk = streamChunk,
}) async* {
  final r = _Reader();
  Uint8List? enc, mac;
  var n = 0;
  var done = false;
  await for (final piece in sealed) {
    if (piece.isEmpty) continue;
    if (done) throw const PrivateLinkException('bytes after the last frame');
    r.add(piece is Uint8List ? piece : Uint8List.fromList(piece));
    while (true) {
      if (enc == null) {
        final head = r.take(_headerLength);
        if (head == null) break;
        if (!sameBytes(head.sublist(0, 4), _streamMagic)) {
          throw const PrivateLinkException('not a sealed stream');
        }
        (enc, mac) = _split(
          key,
          head.sublist(4),
          _utf8('plop stream v1\n$context'),
        );
        continue;
      }
      final word = r.peek(4);
      if (word == null) break;
      final w = word.buffer.asByteData(word.offsetInBytes).getUint32(0);
      final len = w & ~_final;
      if (len > chunk) throw const PrivateLinkException('frame too long');
      final body = r.take(4 + len + _tagLength);
      if (body == null) break;
      yield _open(
        enc,
        mac!,
        _nonce(n++),
        Uint8List.sublistView(body, 0, 4),
        Uint8List.sublistView(body, 4),
      );
      if (w & _final != 0) {
        done = true;
        if (r.length > 0) {
          throw const PrivateLinkException('bytes after the last frame');
        }
        break;
      }
    }
  }
  if (!done) throw const PrivateLinkException('stream cut short');
}

/// Bytes as they arrive, taken out in whole pieces without copying what
/// is waiting more than once.
class _Reader {
  final _q = Queue<Uint8List>();
  int length = 0;

  void add(Uint8List b) {
    _q.add(b);
    length += b.length;
  }

  Uint8List? peek(int n) => length < n ? null : _gather(n, consume: false);
  Uint8List? take(int n) => length < n ? null : _gather(n, consume: true);

  Uint8List _gather(int n, {required bool consume}) {
    final first = _q.first;
    if (first.length >= n) {
      final out = Uint8List.sublistView(first, 0, n);
      if (consume) {
        _q.removeFirst();
        if (first.length > n) _q.addFirst(Uint8List.sublistView(first, n));
        length -= n;
      }
      return out;
    }
    final out = Uint8List(n);
    var got = 0;
    if (!consume) {
      // Only ever a 4-byte peek: walk the pieces, leave them be.
      for (final p in _q) {
        final take = min(n - got, p.length);
        out.setRange(got, got + take, p);
        got += take;
        if (got == n) break;
      }
      return out;
    }
    while (got < n) {
      final p = _q.removeFirst();
      final take = min(n - got, p.length);
      out.setRange(got, got + take, p);
      got += take;
      if (take < p.length) _q.addFirst(Uint8List.sublistView(p, take));
    }
    length -= n;
    return out;
  }
}

// ---------------------------------------------------------------------------
// Request signatures.

/// Header a private-mode request carries: `v1.MS.NONCE.MAC`, the time in
/// ms since the epoch, a 32-hex-digit nonce, and the HMAC-SHA256 of the
/// request in base64url.
const authHeader = 'x-plop-auth';

/// How far a signature's time may be from the receiver's clock, either way.
const authWindow = Duration(seconds: 60);

String _signed(
  String method,
  String path,
  String nodeId,
  int ms,
  String nonce,
) => 'plop-auth-v1\n${method.toUpperCase()}\n$path\n$nodeId\n$ms\n$nonce';

/// The [authHeader] value for [method] on [path] (with its query, if any)
/// from [nodeId], under [authKey]. Returns the header and its nonce, which
/// also keys the sealed answer to this request ([responseContext]).
(String, String) signRequest(
  List<int> authKey, {
  required String method,
  required String path,
  required String nodeId,
  DateTime? now,
}) {
  final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final nonce = hexOf(randomBytes(16));
  final mac = hmacSha256(
    authKey,
    _utf8(_signed(method, path, nodeId, ms, nonce)),
  );
  return ('v1.$ms.$nonce.${b64(mac)}', nonce);
}

/// What a signature covers of [uri]: its path, and its query if it has one.
String pathOf(Uri uri) => uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;

/// What an answer to a signed request is sealed for: the request's nonce,
/// method and path. A recorded answer cannot be passed off as the answer to
/// another request, a stale list to a fresh poll, say.
String responseContext(String nonce, String method, String path) =>
    'answer\n$nonce\n${method.toUpperCase()}\n$path';

/// Checks [authHeader]s on one node: the HMAC, the time within
/// [authWindow] of [clock], and that no nonce is accepted twice while its
/// time is still inside the window (a replay later than that fails on the
/// time). Remembers at most [maxNonces]; past that, the oldest are let go
/// early, which only reopens replays of requests a minute old at most.
class RequestGuard {
  RequestGuard(this.authKey, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final List<int> authKey;
  final DateTime Function() _clock;
  static const maxNonces = 8192;

  /// Nonce to its signature's time, oldest first.
  final _seen = <String, int>{}; // insertion-ordered

  /// The request's nonce if [header] signs [method] on [path] from
  /// [nodeId]; null if it is missing, malformed, wrong, stale or a replay.
  String? verify(
    String? header, {
    required String method,
    required String path,
    required String nodeId,
  }) {
    if (header == null) return null;
    final parts = header.split('.');
    if (parts.length != 4 || parts[0] != 'v1') return null;
    final ms = int.tryParse(parts[1]);
    final nonce = parts[2];
    if (ms == null || !RegExp(r'^[0-9a-f]{32}$').hasMatch(nonce)) return null;
    final now = _clock().millisecondsSinceEpoch;
    if ((now - ms).abs() > authWindow.inMilliseconds) return null;
    final Uint8List mac;
    try {
      mac = unb64(parts[3]);
    } on FormatException {
      return null;
    }
    final want = hmacSha256(
      authKey,
      _utf8(_signed(method, path, nodeId, ms, nonce)),
    );
    if (!sameBytes(mac, want)) return null;
    // Only a valid signature is remembered, so made-up ones cannot push
    // real nonces out early.
    _forgetBefore(now - 2 * authWindow.inMilliseconds);
    if (_seen.containsKey(nonce)) return null;
    _seen[nonce] = ms;
    if (_seen.length > maxNonces) _seen.remove(_seen.keys.first);
    return nonce;
  }

  void _forgetBefore(int ms) {
    // Insertion order is close to time order; a few out of order only
    // stay a little longer.
    while (_seen.isNotEmpty && _seen.values.first < ms) {
      _seen.remove(_seen.keys.first);
    }
  }
}
