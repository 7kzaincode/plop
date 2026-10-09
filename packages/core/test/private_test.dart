import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:plop_core/plop_core.dart';
import 'package:test/test.dart';

import 'sync_test.dart' show eventually, tempFile;

/// Nodes on localhost, each with its own private mode, told about each
/// other by hand: [link] advertises one to another as mDNS would, with
/// its hint and pairing flag as they are at that moment.
class Net {
  Net._(this.root);
  final Directory root;
  final nodes = <PlopNode>[];
  final discoveries = <StaticDiscovery>[];

  static Future<Net> start(List<PrivateMode> modes) async {
    final net = Net._(await Directory.systemTemp.createTemp('plop_private'));
    for (final (i, m) in modes.indexed) {
      final d = StaticDiscovery();
      net.discoveries.add(d);
      net.nodes.add(
        await PlopNode.start(
          dir: Directory('${net.root.path}/n$i'),
          discovery: d,
          name: 'node$i',
          pollInterval: const Duration(milliseconds: 300),
          private: m,
        ),
      );
    }
    return net;
  }

  /// Node [j] as node [i] would find it now.
  void link(int i, int j) {
    final n = nodes[j];
    discoveries[i].add(
      Peer.fromTxt(
        LocalNode(
          id: n.id,
          name: n.store.nodeName,
          port: n.port,
          ips: const [],
          hint: n.private.on ? n.private.circle!.hint : null,
          pairing: n.private.pairingOpen,
        ).txt,
        serviceName: 'svc$j',
        hosts: ['127.0.0.1'],
        port: n.port,
      )!,
    );
  }

  void linkAll() {
    for (var i = 0; i < nodes.length; i++) {
      for (var j = 0; j < nodes.length; j++) {
        if (i != j) link(i, j);
      }
    }
  }

  Future<void> stop() async {
    for (final n in nodes) {
      await n.stop();
    }
    await root.delete(recursive: true);
  }
}

/// Private modes for [n] devices all in one circle, on or [off].
Future<List<PrivateMode>> circleOf(int n, {bool on = true}) async {
  final ids = [for (var i = 0; i < n; i++) await DeviceIdentity.generate()];
  var circle = Circle.create(CircleMember(ids[0].id, 'node0'));
  for (var i = 1; i < n; i++) {
    circle = circle.withMember(CircleMember(ids[i].id, 'node$i'));
  }
  return [
    for (final id in ids)
      await PrivateMode.load({
        'identity': id.toJson(),
        'circle': circle.toJson(),
        'on': on,
      }),
  ];
}

Future<HttpClientResponse> rawGet(
  PlopNode n,
  String path, {
  Map<String, String> headers = const {},
}) async {
  final c = HttpClient();
  final req = await c.getUrl(Uri.parse('http://127.0.0.1:${n.port}$path'));
  headers.forEach(req.headers.set);
  final res = await req.close();
  await res.drain<void>();
  c.close();
  return res;
}

void main() {
  test(
    'two private nodes sync, names and bytes, over sealed answers',
    () async {
      final net = await Net.start(await circleOf(2));
      addTearDown(net.stop);
      net.linkAll();
      final [a, b] = net.nodes;
      await a.addText('hello private');
      final file = await tempFile(net.root, 'big.bin', 3 << 20);
      final big = await a.addFile(file.path);
      await eventually(() => b.items.length == 2);
      // The name came from the sealed list; discovery gave none.
      expect(b.peers.single.name, 'node0');
      expect(b.items.every((i) => i.originName == 'node0'), isTrue);
      final text = b.items.firstWhere((i) => i.kind == ItemKind.text);
      await eventually(() => b.store[text.key]!.isReady);
      expect(
        await File(b.store[text.key]!.path!).readAsString(),
        'hello private',
      );
      // Large enough not to be copied eagerly: a tap, timed.
      final sw = Stopwatch()..start();
      final path = await b.fetch(itemKey(a.id, big.id));
      final mbs = 3 / (sw.elapsedMicroseconds / 1e6);
      print('private download over loopback: ${mbs.toStringAsFixed(1)} MB/s');
      expect(await File(path).readAsBytes(), await file.readAsBytes());
    },
  );

  test('a private and a public node never see each other', () async {
    final modes = await circleOf(2);
    final public = await PrivateMode.load(null);
    final net = await Net.start([modes[0], public]);
    addTearDown(net.stop);
    net.linkAll();
    final [a, b] = net.nodes;
    await a.addText('secret');
    await b.addText('open');
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(a.peers, isEmpty);
    expect(b.peers, isEmpty);
    expect(a.items.length, 1);
    expect(b.items.length, 1);
    // Asking anyway: refused, and nothing in the clear.
    expect(
      NodeClient().fetchList(Uri.parse('http://127.0.0.1:${a.port}'), 'x'),
      throwsA(isA<HttpException>()),
    );
  });

  test('unsigned, wrongly keyed and replayed requests get 401', () async {
    final net = await Net.start(await circleOf(2));
    addTearDown(net.stop);
    final a = net.nodes[0];
    final item = await a.addText('x');
    expect((await rawGet(a, '/v1/items')).statusCode, 401);
    expect((await rawGet(a, '/v1/items/${item.id}')).statusCode, 401);
    final wrong = signRequest(
      randomBytes(32),
      method: 'GET',
      path: '/v1/items',
      nodeId: 'me',
    ).$1;
    expect(
      (await rawGet(
        a,
        '/v1/items',
        headers: {authHeader: wrong, nodeIdHeader: 'me'},
      )).statusCode,
      401,
    );
    final good = signRequest(
      a.private.circle!.authKey,
      method: 'GET',
      path: '/v1/items',
      nodeId: 'me',
    ).$1;
    final h = {authHeader: good, nodeIdHeader: 'me'};
    expect((await rawGet(a, '/v1/items', headers: h)).statusCode, 200);
    expect((await rawGet(a, '/v1/items', headers: h)).statusCode, 401);
    // Signed for another node id: 401.
    final other = signRequest(
      a.private.circle!.authKey,
      method: 'GET',
      path: '/v1/items',
      nodeId: 'me',
    ).$1;
    expect(
      (await rawGet(
        a,
        '/v1/items',
        headers: {authHeader: other, nodeIdHeader: 'you'},
      )).statusCode,
      401,
    );
    // Nudges too.
    final c = HttpClient();
    final post = await c.postUrl(
      Uri.parse('http://127.0.0.1:${a.port}/v1/changed'),
    );
    expect((await post.close()).statusCode, 401);
    c.close();
    // The web shelf is off while private mode is.
    a.web.enabled = true;
    expect((await rawGet(a, '/')).statusCode, 404);
    await a.private.setOn(false);
    expect((await rawGet(a, '/')).statusCode, 200);
    expect((await rawGet(a, '/v1/items')).statusCode, 200);
  });

  test('pairing over HTTP: both see one number, then share a circle', () async {
    final net = await Net.start([
      await PrivateMode.load(null),
      await PrivateMode.load(null),
    ]);
    addTearDown(net.stop);
    final [a, b] = net.nodes;
    expect(a.private.canTurnOn, isFalse);
    a.private.openPairing();
    b.private.openPairing();
    net.linkAll();
    await eventually(() => a.private.candidates.length == 1);
    expect(a.private.candidates.single.name, 'node1');
    await a.private.pairWith(a.private.candidates.single);
    expect(a.private.pairing.step, PairStep.compare);
    expect(b.private.pairing.step, PairStep.compare);
    expect(a.private.pairing.code, b.private.pairing.code);
    expect(a.private.pairing.peerName, 'node1');
    expect(b.private.pairing.peerName, 'node0');
    // A says yes first; it waits for B.
    final confirming = a.private.answer(true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(a.private.pairing.step, PairStep.waiting);
    await b.private.answer(true);
    await confirming;
    expect(a.private.pairing.step, PairStep.done);
    await eventually(() => b.private.pairing.step == PairStep.done);
    final ca = a.private.circle!, cb = b.private.circle!;
    expect(ca.key, cb.key);
    expect(ca.members.length, 2);
    expect(a.private.others.single.name, 'node1');
    expect(b.private.others.single.name, 'node0');
    expect(a.private.pairingOpen, isFalse);
    expect(a.private.canTurnOn, isTrue);

    // And then private mode works between them.
    await a.private.setOn(true);
    await b.private.setOn(true);
    net.linkAll();
    await a.addText('paired');
    await eventually(() => b.items.length == 1);
  });

  test('pairing: a "no" on either side pairs nobody', () async {
    for (final noFromB in [true, false]) {
      final net = await Net.start([
        await PrivateMode.load(null),
        await PrivateMode.load(null),
      ]);
      final [a, b] = net.nodes;
      a.private.openPairing();
      b.private.openPairing();
      net.linkAll();
      await eventually(() => a.private.candidates.isNotEmpty);
      await a.private.pairWith(a.private.candidates.single);
      if (noFromB) {
        await b.private.answer(false);
        await a.private.answer(true);
        expect(a.private.pairing.step, PairStep.failed);
      } else {
        await a.private.answer(false);
        await eventually(() => b.private.pairing.step == PairStep.failed);
      }
      expect(a.private.circle, isNull);
      expect(b.private.circle, isNull);
      await net.stop();
    }
  });

  test('pairing routes answer only while pairing is open', () async {
    final net = await Net.start([await PrivateMode.load(null)]);
    addTearDown(net.stop);
    final a = net.nodes.single;
    final client = NodeClient();
    addTearDown(client.close);
    final base = Uri.parse('http://127.0.0.1:${a.port}');
    final hello = PairingInitiator(
      await DeviceIdentity.generate(),
      'x',
      hasCircle: false,
    ).hello();
    expect((await client.pairPost(base, '/v1/pair/hello', hello)).$1, 404);
    a.private.openPairing();
    expect((await client.pairPost(base, '/v1/pair/hello', hello)).$1, 200);
    // One exchange at a time.
    final second = PairingInitiator(
      await DeviceIdentity.generate(),
      'y',
      hasCircle: false,
    ).hello();
    expect((await client.pairPost(base, '/v1/pair/hello', second)).$1, 409);
    // A reveal that does not match the commit fails the exchange.
    expect(
      (await client.pairPost(base, '/v1/pair/reveal', {
        'sid': 'nope',
        'nonce': b64(randomBytes(16)),
      })).$1,
      404,
    );
    a.private.closePairing(timedOut: true);
    expect(a.private.pairing.message, 'pairing timed out');
  });

  test(
    'a man in the middle on the wire: numbers differ, nothing joins',
    () async {
      // M relays A's hello to B with its own key and answers A as B would.
      final net = await Net.start([
        await PrivateMode.load(null),
        await PrivateMode.load(null),
      ]);
      addTearDown(net.stop);
      final [a, b] = net.nodes;
      b.private.openPairing();
      final client = NodeClient();
      addTearDown(client.close);
      final bBase = Uri.parse('http://127.0.0.1:${b.port}');
      final m = await DeviceIdentity.generate();
      final mToB = PairingInitiator(m, 'node0', hasCircle: false);
      final (_, reply) = await client.pairPost(
        bBase,
        '/v1/pair/hello',
        mToB.hello(),
      );
      mToB.onReply(reply!);
      await client.pairPost(bBase, '/v1/pair/reveal', {
        'sid': reply['sid'],
        ...mToB.reveal(),
      });
      // A, meanwhile, pairs with M as if M were B.
      final aSide = PairingInitiator(
        a.private.identity,
        'node0',
        hasCircle: false,
      );
      final mToA = PairingResponder(m, 'node1', hasCircle: false);
      aSide.onReply(mToA.onHello(aSide.hello()));
      mToA.onReveal(aSide.reveal());
      expect(aSide.code, isNot(b.private.pairing.code));
      // B's user sees a number unlike A's and says no: M's confirm is refused.
      await b.private.answer(false);
      final (status, _) = await client.pairPost(bBase, '/v1/pair/confirm', {
        'sid': reply['sid'],
        'box': b64(mToB.sealConfirm(Circle.create(CircleMember(m.id, 'm')))),
      });
      expect(status, 403);
      expect(b.private.circle, isNull);
    },
  );

  test('forget: a new key reaches the others, not the forgotten', () async {
    final net = await Net.start(await circleOf(3));
    addTearDown(net.stop);
    net.linkAll();
    final [a, b, c] = net.nodes;
    await eventually(() => a.peers.length == 2 && b.peers.length == 2);
    final oldKey = a.private.circle!.key;
    final missed = await a.private.forget(c.private.identity.id);
    expect(missed, isEmpty);
    final ca = a.private.circle!, cb = b.private.circle!;
    expect(ca.key, isNot(oldKey));
    expect(cb.key, ca.key);
    expect(cb.has(c.private.identity.id), isFalse);
    expect(c.private.circle!.key, oldKey);
    // mDNS re-announces with the new hints.
    net.linkAll();
    await eventually(() => a.peers.length == 1 && b.peers.length == 1);
    await eventually(() => c.peers.isEmpty);
    await a.addText('after');
    await eventually(() => b.items.length == 1);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(c.items, isEmpty);
    // C's old key no longer opens anything on A.
    final signed = signRequest(
      oldKey.isEmpty ? Uint8List(32) : c.private.circle!.authKey,
      method: 'GET',
      path: '/v1/items',
      nodeId: c.id,
    ).$1;
    expect(
      (await rawGet(
        a,
        '/v1/items',
        headers: {authHeader: signed, nodeIdHeader: c.id},
      )).statusCode,
      401,
    );
  });

  test('forget names the members it could not reach', () async {
    final net = await Net.start(await circleOf(3));
    addTearDown(net.stop);
    final a = net.nodes[0];
    // Nobody linked: B and C are out of reach.
    final missed = await a.private.forget(net.nodes[2].private.identity.id);
    expect([for (final m in missed) m.name], ['node1']);
  });

  test('leave: off here, and off the others\' lists', () async {
    final net = await Net.start(await circleOf(3));
    addTearDown(net.stop);
    net.linkAll();
    final [a, b, c] = net.nodes;
    await eventually(() => a.peers.length == 2);
    await c.private.leave();
    expect(c.private.circle, isNull);
    expect(c.private.on, isFalse);
    expect(a.private.circle!.has(c.private.identity.id), isFalse);
    expect(b.private.circle!.has(c.private.identity.id), isFalse);
  });

  test(
    'state round-trips through json; a fresh one is saved at once',
    () async {
      Map<String, Object?>? saved;
      final m = await PrivateMode.load(null, save: (j) async => saved = j);
      expect(saved, isNotNull);
      final again = await PrivateMode.load(jsonDecode(jsonEncode(saved)));
      expect(again.identity.id, m.identity.id);
      expect(again.on, isFalse);
      expect(() => again.setOn(true), throwsStateError);
      final modes = await circleOf(2);
      final back = await PrivateMode.load(
        jsonDecode(jsonEncode(modes[0].toJson())),
      );
      expect(back.on, isTrue);
      expect(back.circle!.key, modes[0].circle!.key);
    },
  );

  test('advertising: private hides the name, pairing shows it', () {
    LocalNode self({String? hint, bool pairing = false}) => LocalNode(
      id: '0123456789abcdef',
      name: 'zain mac',
      port: 1,
      ips: const ['10.0.0.2'],
      hint: hint,
      pairing: pairing,
    );
    expect(self().serviceName, 'zain mac');
    expect(self().txt, {
      'id': '0123456789abcdef',
      'v': '1',
      'name': 'zain mac',
      'ips': '10.0.0.2',
    });
    final private = self(hint: 'h');
    expect(private.serviceName, 'plop-01234567');
    expect(private.txt['name'], isNull);
    expect(private.txt['v'], privateV);
    expect(private.txt['c'], 'h');
    expect(self(hint: 'h', pairing: true).txt['name'], 'zain mac');
    Peer? parse(Map<String, String> txt) =>
        Peer.fromTxt(txt, serviceName: 'svc', hosts: const ['h'], port: 1);
    expect(parse(private.txt)!.hint, 'h');
    expect(parse(private.txt)!.name, '');
    expect(parse(self().txt)!.hint, isNull);
    expect(parse({'id': 'x', 'v': '1'})!.name, 'svc');
    expect(parse({'id': 'x', 'v': privateV}), isNull); // no hint
    expect(parse({'id': 'x', 'v': '2'}), isNull);
    expect(parse(self(pairing: true).txt)!.pairing, isTrue);
  });
}
