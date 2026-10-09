import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:plop_core/plop_core.dart';
import 'package:test/test.dart';

/// [bytes] as a stream of pieces of [size], the way a socket hands them
/// over: never along frame boundaries.
Stream<List<int>> pieces(List<int> bytes, int size) async* {
  for (var i = 0; i < bytes.length; i += size) {
    yield bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size);
  }
}

Future<Uint8List> collect(Stream<List<int>> s) async {
  final b = BytesBuilder(copy: false);
  await for (final p in s) {
    b.add(p);
  }
  return b.takeBytes();
}

Future<Uint8List> seal(List<int> plain, List<int> key, String ctx) =>
    collect(sealStream(Stream.value(plain), key, ctx));

void main() {
  final key = randomBytes(32);

  test('hkdf matches package:cryptography', () async {
    for (final (len, salt) in [(32, <int>[]), (64, randomBytes(16))]) {
      final ikm = randomBytes(32), info = utf8.encode('x');
      final want = await DartHkdf(
        hmac: DartHmac.sha256(),
        outputLength: len,
      ).deriveKey(secretKey: SecretKey(ikm), nonce: salt, info: info);
      expect(
        hkdf(ikm, salt: salt, info: info, length: len),
        await want.extractBytes(),
      );
    }
  });

  group('sealed stream', () {
    for (final size in [
      0,
      1,
      streamChunk - 1,
      streamChunk,
      3 * streamChunk + 5,
    ]) {
      test('round-trips $size bytes in odd pieces', () async {
        final plain = randomBytes(size);
        final sealed = await seal(plain, key, 'ctx');
        expect(sealed.length, sealedLength(size));
        for (final piece in [3, 4096, 100000]) {
          expect(
            await collect(openStream(pieces(sealed, piece), key, 'ctx')),
            plain,
          );
        }
      });
    }

    test('two seals of the same bytes differ (fresh salt)', () async {
      final plain = utf8.encode('same');
      expect(await seal(plain, key, 'c'), isNot(await seal(plain, key, 'c')));
    });

    Future<void> refuses(
      List<int> sealed, {
      List<int>? k,
      String ctx = 'ctx',
    }) => expectLater(
      collect(openStream(Stream.value(sealed), k ?? key, ctx)),
      throwsA(isA<PrivateLinkException>()),
    );

    test('a wrong key or context does not open', () async {
      final sealed = await seal(randomBytes(100), key, 'ctx');
      await refuses(sealed, k: randomBytes(32));
      await refuses(sealed, ctx: 'other');
    });

    test('any flipped byte is caught', () async {
      final sealed = await seal(randomBytes(3000), key, 'ctx');
      for (final at in [0, 5, 20, 22, 30, 1500, sealed.length - 1]) {
        final bad = Uint8List.fromList(sealed)..[at] ^= 1;
        await refuses(bad);
      }
    });

    test('truncation is caught, at a frame boundary too', () async {
      final plain = randomBytes(2 * streamChunk + 10);
      final sealed = await seal(plain, key, 'ctx');
      // Mid-frame, and exactly after the second (non-final) frame.
      final twoFrames = 20 + 2 * (4 + streamChunk + 32);
      for (final cut in [10, 20, 100, twoFrames, sealed.length - 1]) {
        await refuses(sealed.sublist(0, cut));
      }
    });

    test('bytes after the last frame are refused', () async {
      final sealed = await seal(randomBytes(10), key, 'ctx');
      await refuses([...sealed, 0]);
    });

    test('frames cannot be reordered or dropped', () async {
      final sealed = await seal(randomBytes(3 * streamChunk), key, 'ctx');
      const f = 4 + streamChunk + 32;
      final head = sealed.sublist(0, 20);
      final f1 = sealed.sublist(20, 20 + f),
          f2 = sealed.sublist(20 + f, 20 + 2 * f);
      final rest = sealed.sublist(20 + 2 * f);
      await refuses([...head, ...f2, ...f1, ...rest]);
      await refuses([...head, ...f1, ...rest]);
    });

    test('an oversized frame is refused before it is buffered', () async {
      final sealed = await seal(randomBytes(10), key, 'ctx');
      final bad = Uint8List.fromList(sealed);
      bad.buffer.asByteData().setUint32(20, 0x80000000 | (1 << 30));
      await refuses(bad);
    });

    test('throughput', () async {
      const mb = 64;
      final chunk = Uint8List(1 << 20);
      Stream<List<int>> source() async* {
        for (var i = 0; i < mb; i++) {
          yield chunk;
        }
      }

      final sw = Stopwatch()..start();
      var n = 0;
      await for (final p in openStream(
        sealStream(source(), key, 'b'),
        key,
        'b',
      )) {
        n += p.length;
      }
      expect(n, mb << 20);
      final rate = mb / (sw.elapsedMicroseconds / 1e6);
      // Seal and open on one core, so a transfer (one side each) runs at
      // about twice this. Printed for the record, not asserted tightly:
      // CI machines vary.
      print('seal+open: ${rate.toStringAsFixed(1)} MB/s');
      expect(rate, greaterThan(5));
    });
  });

  group('sealed box', () {
    test('round-trips, and is tied to key and context', () {
      final box = sealBox(key, 'a', utf8.encode('hi'));
      expect(utf8.decode(openBox(key, 'a', box)), 'hi');
      expect(
        () => openBox(key, 'b', box),
        throwsA(isA<PrivateLinkException>()),
      );
      expect(
        () => openBox(randomBytes(32), 'a', box),
        throwsA(isA<PrivateLinkException>()),
      );
      final bad = Uint8List.fromList(box)..[box.length - 40] ^= 1;
      expect(
        () => openBox(key, 'a', bad),
        throwsA(isA<PrivateLinkException>()),
      );
      expect(
        () => openBox(key, 'a', [1, 2]),
        throwsA(isA<PrivateLinkException>()),
      );
    });
  });

  group('request signatures', () {
    final auth = randomBytes(32);
    var now = DateTime(2026, 10, 9, 12);
    late RequestGuard guard;
    setUp(() {
      now = DateTime(2026, 10, 9, 12);
      guard = RequestGuard(auth, clock: () => now);
    });

    String sign({
      List<int>? k,
      String method = 'GET',
      String path = '/v1/items',
      String node = 'abc',
      Duration skew = Duration.zero,
    }) => signRequest(
      k ?? auth,
      method: method,
      path: path,
      nodeId: node,
      now: now.add(skew),
    ).$1;

    String? verify(
      String? h, {
      String method = 'GET',
      String path = '/v1/items',
      String node = 'abc',
    }) => guard.verify(h, method: method, path: path, nodeId: node);

    test('accepts a good one and hands back its nonce', () {
      final (h, nonce) = signRequest(
        auth,
        method: 'GET',
        path: '/v1/items',
        nodeId: 'abc',
        now: now,
      );
      expect(verify(h), nonce);
    });

    test('rejects a missing, malformed or wrongly keyed one', () {
      expect(verify(null), isNull);
      expect(verify('v1.x.y.z'), isNull);
      expect(verify('nonsense'), isNull);
      expect(verify(sign(k: randomBytes(32))), isNull);
    });

    test('is tied to method, path and node id', () {
      expect(verify(sign(), method: 'POST'), isNull);
      expect(verify(sign(), path: '/v1/items/x'), isNull);
      expect(verify(sign(), node: 'other'), isNull);
    });

    test('accepts up to 60 s of clock skew either way, no more', () {
      expect(verify(sign(skew: const Duration(seconds: 59))), isNotNull);
      expect(verify(sign(skew: const Duration(seconds: -59))), isNotNull);
      expect(verify(sign(skew: const Duration(seconds: 61))), isNull);
      expect(verify(sign(skew: const Duration(seconds: -61))), isNull);
    });

    test('a replay is refused, inside the window and after it', () {
      final h = sign();
      expect(verify(h), isNotNull);
      expect(verify(h), isNull);
      now = now.add(const Duration(seconds: 30));
      expect(verify(h), isNull);
      now = now.add(const Duration(minutes: 5));
      expect(verify(h), isNull); // stale by then
    });

    test('a tampered signature is refused', () {
      final h = sign();
      final parts = h.split('.');
      final ts = int.parse(parts[1]) + 1;
      expect(verify([parts[0], '$ts', parts[2], parts[3]].join('.')), isNull);
    });
  });

  test('responseContext ties an answer to its request', () async {
    final sealed = await seal(
      [1, 2, 3],
      key,
      responseContext('n1', 'GET', '/v1/items'),
    );
    await expectLater(
      collect(
        openStream(
          Stream.value(sealed),
          key,
          responseContext('n2', 'GET', '/v1/items'),
        ),
      ),
      throwsA(isA<PrivateLinkException>()),
    );
  });

  test('a stream that errors part way passes the error on', () async {
    final sealed = await seal(randomBytes(200000), key, 'ctx');
    final c = StreamController<List<int>>();
    final opened = collect(openStream(c.stream, key, 'ctx'));
    c
      ..add(sealed.sublist(0, 70000))
      ..addError(const FormatException('reset'));
    unawaited(c.close());
    await expectLater(opened, throwsFormatException);
  });
}
