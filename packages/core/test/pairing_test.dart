import 'dart:convert';

import 'package:plop_core/plop_core.dart';
import 'package:test/test.dart';

/// Runs hello, reply and reveal between [a] and [b] directly.
void exchange(PairingInitiator a, PairingResponder b) {
  final reply = b.onHello(a.hello());
  a.onReply(reply);
  b.onReveal(a.reveal());
}

void main() {
  late DeviceIdentity ia, ib, im;
  setUpAll(() async {
    (ia, ib, im) = await (
      DeviceIdentity.generate(),
      DeviceIdentity.generate(),
      DeviceIdentity.generate(),
    ).wait;
  });

  test('identity round-trips through json and agrees both ways', () {
    final back = DeviceIdentity.fromJson(ia.toJson());
    expect(back.publicKey, ia.publicKey);
    expect(ia.agree(ib.publicKey), ib.agree(ia.publicKey));
    expect(
      () => ia.agree(List.filled(32, 0)),
      throwsA(isA<PrivateLinkException>()),
    );
    expect(() => ia.agree([1, 2]), throwsA(isA<PrivateLinkException>()));
  });

  test('a member box opens only for its addressee, from its sender', () {
    final box = ia.sealFor(ib.publicKey, 'c', utf8.encode('k'));
    expect(utf8.decode(ib.openFrom(ia.publicKey, 'c', box)), 'k');
    expect(
      () => im.openFrom(ia.publicKey, 'c', box),
      throwsA(isA<PrivateLinkException>()),
    );
    expect(
      () => ib.openFrom(im.publicKey, 'c', box),
      throwsA(isA<PrivateLinkException>()),
    );
  });

  test('both sides show the same code and share a key', () {
    final a = PairingInitiator(ia, 'a', hasCircle: false);
    final b = PairingResponder(ib, 'b', hasCircle: false);
    exchange(a, b);
    expect(a.code, matches(RegExp(r'^\d{6}$')));
    expect(a.code, b.code);
    expect(a.key, b.key);
    expect(a.theirName, 'b');
    expect(b.theirName, 'a');
  });

  test('the circle is handed over sealed, and only opens for the pair', () {
    final a = PairingInitiator(ia, 'a', hasCircle: true);
    final b = PairingResponder(ib, 'b', hasCircle: true);
    exchange(a, b);
    expect(a.provides, isTrue); // the initiator's circle wins a tie
    expect(b.provides, isFalse);
    final circle = Circle.create(
      CircleMember(ia.id, 'a'),
    ).withMember(CircleMember(ib.id, 'b'));
    final sealed = a.sealConfirm(circle);
    expect(b.openConfirm(sealed)!.key, circle.key);
    expect(
      () => b.openConfirm(b.sealConfirm(null)),
      throwsA(isA<PairingException>()),
    );
    expect(a.openConfirm(b.sealConfirm(circle)), isNull); // b provides none
  });

  test('who provides the circle', () {
    bool aProvides(bool aHas, bool bHas) {
      final a = PairingInitiator(ia, 'a', hasCircle: aHas);
      final b = PairingResponder(ib, 'b', hasCircle: bHas);
      exchange(a, b);
      expect(b.provides, !a.provides);
      return a.provides;
    }

    expect(aProvides(false, false), isTrue);
    expect(aProvides(true, false), isTrue);
    expect(aProvides(true, true), isTrue);
    expect(aProvides(false, true), isFalse);
  });

  test('a reveal that does not match its commit is refused', () {
    final a = PairingInitiator(ia, 'a', hasCircle: false);
    final b = PairingResponder(ib, 'b', hasCircle: false);
    a.onReply(b.onHello(a.hello()));
    final other = PairingInitiator(ia, 'a', hasCircle: false);
    expect(() => b.onReveal(other.reveal()), throwsA(isA<PairingException>()));
  });

  test('malformed messages are refused', () {
    final b = PairingResponder(ib, 'b', hasCircle: false);
    expect(() => b.onHello({'v': 2}), throwsA(isA<PairingException>()));
    expect(
      () => PairingResponder(
        ib,
        'b',
        hasCircle: false,
      ).onHello({'v': 1, 'pk': 'x', 'name': 'a', 'commit': 'y'}),
      throwsA(isA<PairingException>()),
    );
    final a = PairingInitiator(ib, 'b', hasCircle: false);
    final self = PairingResponder(ib, 'b', hasCircle: false);
    expect(() => self.onHello(a.hello()), throwsA(isA<PairingException>()));
  });

  test('a man in the middle gets mismatched numbers', () {
    // M sits between A and B, answering each with its own key. It plays
    // both orders: finishing with A first, then B, and the other way.
    var matched = 0;
    const tries = 300;
    for (var i = 0; i < tries; i++) {
      final a = PairingInitiator(ia, 'a', hasCircle: false);
      final b = PairingResponder(ib, 'b', hasCircle: false);
      final mToA = PairingResponder(im, 'b', hasCircle: false);
      final mToB = PairingInitiator(im, 'a', hasCircle: false);
      if (i.isEven) {
        a.onReply(mToA.onHello(a.hello()));
        mToA.onReveal(a.reveal());
        mToB.onReply(b.onHello(mToB.hello()));
        b.onReveal(mToB.reveal());
      } else {
        mToB.onReply(b.onHello(mToB.hello()));
        b.onReveal(mToB.reveal());
        a.onReply(mToA.onHello(a.hello()));
        mToA.onReveal(a.reveal());
      }
      if (a.code == b.code) matched++;
      // And the keys A and B hold are not the same key, so even a lucky
      // match would hand M two different sessions, not the circle in the
      // clear... but M holds both, which is why the numbers are the check.
      expect(a.key, isNot(b.key));
    }
    // One in a million per try; 300 tries all but never match.
    expect(matched, 0);
  });

  test('a MITM cannot reuse A\'s commit with its own key', () {
    // Forwarding A's hello with its own key swapped in breaks the commit,
    // which binds A's key.
    final a = PairingInitiator(ia, 'a', hasCircle: false);
    final b = PairingResponder(ib, 'b', hasCircle: false);
    final hello = {...a.hello(), 'pk': im.id};
    final reply = b.onHello(hello);
    a.onReply(reply);
    expect(() => b.onReveal(a.reveal()), throwsA(isA<PairingException>()));
  });

  group('circle', () {
    test('json, derived keys, members and rotation', () {
      final c = Circle.create(
        CircleMember(ia.id, 'a'),
      ).withMember(CircleMember(ib.id, 'b'));
      final back = Circle.fromJson(jsonDecode(jsonEncode(c.toJson())));
      expect(back.key, c.key);
      expect(back.hint, c.hint);
      expect(back.members, c.members);
      expect(back.epoch, 2);
      expect(c.hint, hasLength(16));
      expect(c.hint, isNot(c.id));
      expect(c.authKey, isNot(c.bodyKey));
      final rotated = c.without(ib.id);
      expect(rotated.key, isNot(c.key));
      expect(rotated.hint, isNot(c.hint));
      expect(rotated.epoch, 3);
      expect(rotated.has(ib.id), isFalse);
      expect(rotated.has(ia.id), isTrue);
      expect(
        () => Circle.fromJson({'key': 'AA', 'epoch': 1, 'members': []}),
        throwsFormatException,
      );
    });
  });
}
