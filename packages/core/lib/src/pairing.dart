import 'dart:convert';
import 'dart:typed_data';

import 'circle.dart';
import 'private_link.dart';

// Pairing two devices with nothing typed: an X25519 exchange, then a
// 6-digit number both screens show and the user compares, as Bluetooth's
// numeric comparison does. Only the messages and the maths live here; how
// they travel (HTTP on the LAN today, see PrivateMode) is up to the caller.
//
// The exchange, initiator A and responder B:
//
//   A -> B  hello   A's public key, name, commit = SHA-256(A's key, nA)
//   B -> A  reply   B's public key, name, nB
//   A -> B  reveal  nA; B checks it against the commit
//
// Both then show code(A's key, B's key, nA, nB). An attacker in the middle
// talks to each side with its own key, so the two numbers come from
// different inputs, and it would need them to agree. It cannot steer the
// one A sees: A committed to nA before seeing anything from the attacker.
// Nor the one B sees: B's nB comes after the attacker's commit to its own
// nonce. One try in a million, and a failed try shows mismatched numbers.

/// What the commit hashes; a label, then the key and the nonce.
Uint8List pairingCommit(List<int> publicKey, List<int> nonce) =>
    sha256Of([...utf8.encode('plop pair commit v1'), ...publicKey, ...nonce]);

/// The six digits both screens show, from both keys and both nonces, the
/// initiator's first.
String pairingCode(
  List<int> keyA,
  List<int> keyB,
  List<int> nonceA,
  List<int> nonceB,
) {
  final h = sha256Of([
    ...utf8.encode('plop pair code v1'),
    ...keyA,
    ...keyB,
    ...nonceA,
    ...nonceB,
  ]);
  final n = h.buffer.asByteData().getUint32(0) % 1000000;
  return n.toString().padLeft(6, '0');
}

/// The key the two devices share once the numbers match; it seals the
/// circle as it is handed over.
Uint8List pairingKey(
  Uint8List shared,
  List<int> keyA,
  List<int> keyB,
  List<int> nonceA,
  List<int> nonceB,
) => hkdf(
  shared,
  salt: [...nonceA, ...nonceB],
  info: [...utf8.encode('plop pair key v1'), ...keyA, ...keyB],
);

/// Something in the exchange did not add up: a message that is not one, a
/// reveal that does not match its commit, a key that will not do.
class PairingException implements Exception {
  const PairingException(this.message);
  final String message;

  @override
  String toString() => 'pairing: $message';
}

Uint8List _bytes(Map<String, Object?> m, String k, int length) {
  try {
    final b = unb64(m[k] as String);
    if (b.length == length) return b;
  } catch (_) {
    // below
  }
  throw PairingException('bad $k');
}

String _name(Map<String, Object?> m) {
  final n = m['name'];
  if (n is! String) throw const PairingException('bad name');
  // A name for showing: a line at most, without control characters.
  final clean = n.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  return clean.length > 64 ? clean.substring(0, 64) : clean;
}

/// One side's view of an exchange that got as far as the number.
abstract class PairingSide {
  PairingSide(this.self, this.name, {required this.hasCircle});

  final DeviceIdentity self;
  final String name;

  /// Whether this side was in a circle when the exchange began; decides
  /// whose circle the pair ends up in ([initiatorProvides]).
  final bool hasCircle;

  final Uint8List nonce = randomBytes(16);

  late final Uint8List theirKey;
  late final String theirName;
  late final bool theyHaveCircle;

  /// The six digits to show; set once both nonces are known.
  String? code;

  /// The shared key; set with [code].
  Uint8List? key;

  bool get isInitiator;

  /// Whose circle the pair ends up in: the initiator's when it has one or
  /// neither has (it makes one then), else the responder's. A responder in
  /// another circle leaves it.
  bool get initiatorProvides =>
      (isInitiator ? hasCircle : theyHaveCircle) ||
      !(isInitiator ? theyHaveCircle : hasCircle);

  /// Whether this side hands its circle over (rather than joining).
  bool get provides => isInitiator == initiatorProvides;

  void _finish(List<int> nonceA, List<int> nonceB) {
    final (a, b) = isInitiator
        ? (self.publicKey, theirKey)
        : (theirKey, self.publicKey);
    code = pairingCode(a, b, nonceA, nonceB);
    key = pairingKey(self.agree(theirKey), a, b, nonceA, nonceB);
  }

  /// What this side sends once its user said the numbers match, sealed
  /// under the shared key: the circle when it [provides] one, else
  /// nothing but its name.
  Uint8List sealConfirm(Circle? circle) => sealBox(
    key!,
    isInitiator ? 'pair confirm a' : 'pair confirm b',
    utf8.encode(
      jsonEncode({'name': name, 'circle': provides ? circle?.toJson() : null}),
    ),
  );

  /// The other side's [sealConfirm]: the circle it handed over, if any.
  /// Throws [PairingException] if it does not open.
  Circle? openConfirm(List<int> sealed) {
    try {
      final j =
          jsonDecode(
                utf8.decode(
                  openBox(
                    key!,
                    isInitiator ? 'pair confirm b' : 'pair confirm a',
                    sealed,
                  ),
                ),
              )
              as Map;
      final c = j['circle'];
      return c == null ? null : Circle.fromJson((c as Map).cast());
    } on PairingException {
      rethrow;
    } catch (_) {
      throw const PairingException('confirm does not open');
    }
  }
}

/// The side that started it, by picking the other from a list.
class PairingInitiator extends PairingSide {
  PairingInitiator(super.self, super.name, {required super.hasCircle});

  @override
  bool get isInitiator => true;

  Map<String, Object?> hello() => {
    'v': 1,
    'pk': self.id,
    'name': name,
    'commit': b64(pairingCommit(self.publicKey, nonce)),
    'circle': hasCircle,
  };

  /// Takes the responder's reply; [code] and [key] are set after it.
  void onReply(Map<String, Object?> reply) {
    theirKey = _bytes(reply, 'pk', 32);
    theirName = _name(reply);
    theyHaveCircle = reply['circle'] == true;
    final theirNonce = _bytes(reply, 'nonce', 16);
    if (sameBytes(theirKey, self.publicKey)) {
      throw const PairingException('that is this device');
    }
    _finish(nonce, theirNonce);
  }

  Map<String, Object?> reveal() => {'nonce': b64(nonce)};
}

/// The side that was picked.
class PairingResponder extends PairingSide {
  PairingResponder(super.self, super.name, {required super.hasCircle});

  @override
  bool get isInitiator => false;

  late final Uint8List _commit;

  /// Takes the initiator's hello and answers it.
  Map<String, Object?> onHello(Map<String, Object?> hello) {
    if (hello['v'] != 1) throw const PairingException('unknown version');
    theirKey = _bytes(hello, 'pk', 32);
    theirName = _name(hello);
    theyHaveCircle = hello['circle'] == true;
    _commit = _bytes(hello, 'commit', 32);
    if (sameBytes(theirKey, self.publicKey)) {
      throw const PairingException('that is this device');
    }
    return {
      'pk': self.id,
      'name': name,
      'nonce': b64(nonce),
      'circle': hasCircle,
    };
  }

  /// Takes the initiator's nonce; throws [PairingException] if it is not
  /// the one it committed to. [code] and [key] are set after it.
  void onReveal(Map<String, Object?> reveal) {
    final theirNonce = _bytes(reveal, 'nonce', 16);
    if (!sameBytes(pairingCommit(theirKey, theirNonce), _commit)) {
      throw const PairingException('reveal does not match the commit');
    }
    _finish(theirNonce, nonce);
  }
}
