import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart'
    show KeyPairType, SecretKeyData, SimpleKeyPairData, SimplePublicKey;
import 'package:cryptography/dart.dart' show DartX25519;

import 'private_link.dart';

// A device's long-term key and the circle of devices it is paired with.
// Nothing here knows how devices find or reach each other: the same keys
// work over the LAN today and through a relay later. See docs/PROTOCOL.md,
// "Private mode".

const _x25519 = DartX25519();

/// This device's long-term X25519 key pair, made once and kept with its
/// settings. The public half is how other devices in a circle know it;
/// the private half never leaves the device.
class DeviceIdentity {
  DeviceIdentity(this.privateKey, this.publicKey)
    : assert(privateKey.length == 32 && publicKey.length == 32);

  final Uint8List privateKey;
  final Uint8List publicKey;

  /// [publicKey] as members lists and messages carry it.
  String get id => b64(publicKey);

  static Future<DeviceIdentity> generate() async {
    final pair = await _x25519.newKeyPairFromSeed(randomBytes(32));
    final public = await pair.extractPublicKey();
    return DeviceIdentity(
      Uint8List.fromList(await pair.extractPrivateKeyBytes()),
      Uint8List.fromList(public.bytes),
    );
  }

  /// The X25519 shared secret with [theirs]. Throws [PrivateLinkException]
  /// for a key that is not 32 bytes, or one of the few points that would
  /// make the secret all zeros whatever this side's key: a peer must not
  /// be able to pick the secret.
  Uint8List agree(List<int> theirs) {
    if (theirs.length != 32) {
      throw const PrivateLinkException('not an X25519 key');
    }
    final secret = _x25519.sharedSecretSync(
      keyPairData: SimpleKeyPairData(
        privateKey,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      ),
      remotePublicKey: SimplePublicKey(theirs, type: KeyPairType.x25519),
    );
    final bytes = Uint8List.fromList((secret as SecretKeyData).bytes);
    if (bytes.every((b) => b == 0)) {
      throw const PrivateLinkException('weak X25519 key');
    }
    return bytes;
  }

  /// [plain] sealed so that only the device holding [theirKey]'s private
  /// half can open it, and it knows this device sent it: the key comes from
  /// both long-term keys (static X25519), so not even another member of
  /// the circle can read or forge it. How a new circle key reaches the
  /// members that remain when one is forgotten.
  Uint8List sealFor(List<int> theirKey, String context, List<int> plain) =>
      sealBox(_pairKey(publicKey, theirKey, theirKey), context, plain);

  /// Opens what the device holding [theirKey] sealed for this one with
  /// [sealFor]; throws [PrivateLinkException] otherwise.
  Uint8List openFrom(List<int> theirKey, String context, List<int> sealed) =>
      openBox(_pairKey(theirKey, publicKey, theirKey), context, sealed);

  Uint8List _pairKey(List<int> from, List<int> to, List<int> theirs) => hkdf(
    agree(theirs),
    info: [...utf8.encode('plop member box v1'), ...from, ...to],
  );

  Map<String, Object?> toJson() => {
    'sk': b64(privateKey),
    'pk': b64(publicKey),
  };

  /// Throws a [FormatException] for anything that is not a key pair.
  static DeviceIdentity fromJson(Map<String, Object?> j) {
    final sk = unb64(j['sk'] as String), pk = unb64(j['pk'] as String);
    if (sk.length != 32 || pk.length != 32) {
      throw const FormatException('bad key pair');
    }
    return DeviceIdentity(sk, pk);
  }
}

/// A device in a circle: its public key ([DeviceIdentity.id]) and the name
/// it had when it joined.
class CircleMember {
  const CircleMember(this.publicKey, this.name);
  final String publicKey;
  final String name;

  Map<String, Object?> toJson() => {'pk': publicKey, 'name': name};

  static CircleMember fromJson(Map<String, Object?> j) =>
      CircleMember(j['pk'] as String, j['name'] as String? ?? '');

  @override
  bool operator ==(Object other) =>
      other is CircleMember &&
      other.publicKey == publicKey &&
      other.name == name;

  @override
  int get hashCode => Object.hash(publicKey, name);
}

/// A set of paired devices: one random 32-byte key they all hold, and who
/// they are. Every circle-level key (the discovery hint, request
/// signatures, sealed bodies) is derived from [key] with HKDF, each for one
/// purpose. [epoch] goes up with every change, so of two versions the
/// newer wins; a new [key] comes with every forget.
class Circle {
  Circle({required this.key, required this.epoch, required this.members})
    : assert(key.length == 32);

  final Uint8List key;
  final int epoch;
  final List<CircleMember> members;

  /// A new circle of just [self], with a fresh key.
  factory Circle.create(CircleMember self) =>
      Circle(key: randomBytes(32), epoch: 1, members: [self]);

  /// Names the circle without giving away its key; 16 hex digits.
  late final String id = hexOf(
    sha256Of([...utf8.encode('plop circle id v1'), ...key]),
  ).substring(0, 16);

  /// What private mode advertises on the network instead of a name: other
  /// members recognise it, nobody else learns anything but that the same
  /// circle is around. 16 hex digits.
  late final String hint = hexOf(
    hmacSha256(key, utf8.encode('plop-circle')),
  ).substring(0, 16);

  /// Signs and checks requests ([signRequest], [RequestGuard]).
  late final Uint8List authKey = hkdf(key, info: utf8.encode('plop auth v1'));

  /// Seals answers ([sealStream]).
  late final Uint8List bodyKey = hkdf(key, info: utf8.encode('plop body v1'));

  bool has(String publicKey) => members.any((m) => m.publicKey == publicKey);

  CircleMember? member(String publicKey) =>
      members.where((m) => m.publicKey == publicKey).firstOrNull;

  /// The same key, with [m] added (or its name brought up to date).
  Circle withMember(CircleMember m) => Circle(
    key: key,
    epoch: epoch + 1,
    members: [
      for (final x in members)
        if (x.publicKey != m.publicKey) x,
      m,
    ],
  );

  /// Without [publicKey], and under a new key: the device that left still
  /// knows the old one.
  Circle without(String publicKey) => Circle(
    key: randomBytes(32),
    epoch: epoch + 1,
    members: [
      for (final x in members)
        if (x.publicKey != publicKey) x,
    ],
  );

  /// Without [publicKey], same key and epoch: a member that said it left,
  /// and so no longer needs to be kept out.
  Circle dropping(String publicKey) => Circle(
    key: key,
    epoch: epoch,
    members: [
      for (final x in members)
        if (x.publicKey != publicKey) x,
    ],
  );

  Map<String, Object?> toJson() => {
    'key': b64(key),
    'epoch': epoch,
    'members': [for (final m in members) m.toJson()],
  };

  /// Throws a [FormatException] (or a [TypeError]) for anything that is not
  /// a circle.
  static Circle fromJson(Map<String, Object?> j) {
    final key = unb64(j['key'] as String);
    final epoch = j['epoch'] as int;
    if (key.length != 32 || epoch < 1) {
      throw const FormatException('bad circle');
    }
    return Circle(
      key: key,
      epoch: epoch,
      members: [
        for (final m in j['members'] as List)
          CircleMember.fromJson((m as Map).cast()),
      ],
    );
  }
}
