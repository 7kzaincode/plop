import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'circle.dart';
import 'discovery.dart';
import 'item.dart';
import 'node_client.dart';
import 'node_server.dart';
import 'pairing.dart';
import 'private_link.dart';
import 'sync_engine.dart';

// Private mode on the LAN: this device's key and circle, kept with its
// settings; the pairing flow the settings panel drives, carried over
// /v1/pair; the /v1/circle routes members use to hand each other a new
// circle; and the check every other /v1 request passes while it is on. The
// keys and the maths are in circle.dart, pairing.dart and private_link.dart,
// which know nothing of the LAN.

/// Where a pairing stands, as the settings panel shows it.
enum PairStep {
  /// Nothing going on.
  idle,

  /// Reaching the other device, or being reached.
  connecting,

  /// Both screens show [PairingStatus.code]; waiting for this side's user.
  compare,

  /// This side's user said the numbers match; waiting for the other's.
  waiting,

  /// Paired.
  done,

  /// Not paired; [PairingStatus.message] says why.
  failed,
}

class PairingStatus {
  const PairingStatus(this.step, {this.peerName, this.code, this.message});
  static const idle = PairingStatus(PairStep.idle);

  final PairStep step;

  /// The other device, once known.
  final String? peerName;

  /// The six digits, from [PairStep.compare] on.
  final String? code;

  /// Why it failed, or who it paired with.
  final String? message;

  bool get busy =>
      step == PairStep.connecting ||
      step == PairStep.compare ||
      step == PairStep.waiting;
}

/// One pairing exchange, from either side.
class _Session {
  _Session(this.side, {this.sid, this.peer});
  final PairingSide side;
  String? sid;

  /// The device being paired with, when this side started it.
  final Peer? peer;
  Uri? base;

  /// What this side's user said: null until they said it.
  bool? answer;

  /// The responder's sealed answer once it is done, given again should the
  /// initiator ask again (its first answer lost on the way).
  String? doneReply;
}

/// This device's private mode: its key, its circle, whether private mode
/// is on, and pairing. Lives as long as the app; a [PlopNode] wires it to
/// its server, client, sync engine and discovery.
class PrivateMode {
  PrivateMode._(this.identity, this._circle, this._on, this._save) {
    _guard = _circle == null ? null : RequestGuard(_circle!.authKey);
  }

  /// What [toJson] wrote, or null (or anything unreadable) for a device
  /// that has none yet: it gets a new key, saved at once, so it keeps it.
  /// [save] writes the JSON wherever the app keeps it; the app's is a file
  /// only this user can read.
  static Future<PrivateMode> load(
    Map<String, Object?>? json, {
    Future<void> Function(Map<String, Object?> json)? save,
  }) async {
    DeviceIdentity? id;
    Circle? circle;
    var on = false;
    try {
      id = DeviceIdentity.fromJson((json!['identity'] as Map).cast());
      final c = json['circle'];
      circle = c == null ? null : Circle.fromJson((c as Map).cast());
      if (circle != null && !circle.has(id.id)) circle = null;
      on = json['on'] == true;
    } catch (_) {
      // None yet, or unreadable: a fresh key, no circle.
    }
    final fresh = id == null;
    final mode = PrivateMode._(
      id ?? await DeviceIdentity.generate(),
      circle,
      on && circle != null,
      save,
    );
    if (fresh) await mode._persist().catchError((_) {});
    return mode;
  }

  final DeviceIdentity identity;
  Circle? _circle;
  bool _on;
  final Future<void> Function(Map<String, Object?>)? _save;
  RequestGuard? _guard;

  Map<String, Object?> toJson() => {
    'v': 1,
    'identity': identity.toJson(),
    'circle': _circle?.toJson(),
    'on': _on,
  };

  Future<void> _persist() async => _save?.call(toJson());

  /// Fires on anything the settings panel shows: the circle, on or off,
  /// pairing's window and status, devices nearby with pairing open.
  Stream<void> get changes => _changes.stream;
  final _changes = StreamController<void>.broadcast();
  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Circle? get circle => _circle;

  /// On only with a circle to be private with.
  bool get on => _on && _circle != null;

  /// The circle's other devices.
  List<CircleMember> get others => [
    for (final m in _circle?.members ?? const <CircleMember>[])
      if (m.publicKey != identity.id) m,
  ];

  /// Whether private mode can be switched on: there is someone to see.
  bool get canTurnOn => others.isNotEmpty;

  /// Switches private mode; switching on needs [canTurnOn]. Completes once
  /// saved, or fails if it could not be: it holds until plop quits anyway.
  Future<void> setOn(bool value) async {
    if (value && !canTurnOn) throw StateError('no other device paired');
    if (_on == value) return;
    _on = value;
    _changed();
    await _persist();
  }

  // -------------------------------------------------------------------------
  // Wiring, by PlopNode.

  String _nodeId = '';
  String _name = '';
  NodeClient? _client;
  SyncEngine? _engine;
  StreamSubscription<void>? _peerSub;

  void attach({
    required String nodeId,
    required String name,
    required NodeClient client,
    required SyncEngine engine,
  }) {
    _nodeId = nodeId;
    _name = name;
    _client = client;
    _engine = engine;
    _peerSub = engine.peerChanges.listen((_) => _changed());
  }

  Future<void> detach() async {
    await _peerSub?.cancel();
    _peerSub = null;
    _pairingTimer?.cancel();
    _pairingUntil = null;
    _session = null;
    _client = null;
    _engine = null;
  }

  // -------------------------------------------------------------------------
  // Pairing.

  /// How long pairing stays open once the panel opens it.
  static const pairingWindow = Duration(minutes: 2);

  DateTime? _pairingUntil;
  Timer? _pairingTimer;
  _Session? _session;
  PairingStatus _status = PairingStatus.idle;

  /// Whether this device is listed nearby to pair with, and answers
  /// /v1/pair.
  bool get pairingOpen => _pairingUntil != null;

  /// When pairing closes by itself.
  DateTime? get pairingUntil => _pairingUntil;

  PairingStatus get pairing => _status;

  /// Devices nearby with pairing open, whatever their mode.
  List<Peer> get candidates => _engine?.pairingPeers ?? const [];

  /// Opens pairing for [pairingWindow], or that long from now if it is
  /// open already. A failed or finished exchange is cleared.
  void openPairing({Duration window = pairingWindow}) {
    _pairingTimer?.cancel();
    _pairingUntil = DateTime.now().add(window);
    _pairingTimer = Timer(window, () => closePairing(timedOut: true));
    if (!_status.busy) _status = PairingStatus.idle;
    _changed();
  }

  /// Closes pairing: the panel was closed, or it ran out of time. An
  /// exchange still going fails.
  void closePairing({bool timedOut = false}) {
    _pairingTimer?.cancel();
    _pairingTimer = null;
    _pairingUntil = null;
    if (_status.busy) {
      _status = PairingStatus(
        PairStep.failed,
        peerName: _status.peerName,
        message: timedOut ? 'pairing timed out' : 'pairing stopped',
      );
    }
    _session = null;
    _changed();
  }

  void _set(PairingStatus s) {
    _status = s;
    _changed();
  }

  void _fail(_Session s, String message) {
    if (_session != s) return;
    _session = null;
    _set(
      PairingStatus(
        PairStep.failed,
        peerName: _status.peerName,
        message: message,
      ),
    );
  }

  /// Pairs with [peer], a device listed in [candidates]: this side starts
  /// the exchange and shows the number once both have it.
  Future<void> pairWith(Peer peer) async {
    final client = _client;
    if (client == null || _status.busy || !pairingOpen) return;
    final side = PairingInitiator(identity, _name, hasCircle: _circle != null);
    final s = _session = _Session(side, peer: peer);
    _set(PairingStatus(PairStep.connecting, peerName: peer.name));
    try {
      int? status;
      Map<String, Object?>? reply;
      for (final base in peer.baseUris) {
        try {
          (status, reply) = await client.pairPost(
            base,
            '/v1/pair/hello',
            side.hello(),
          );
          s.base = base;
          break;
        } catch (_) {
          // the next address
        }
      }
      if (_session != s) return; // stopped, or the other side started too
      if (status == HttpStatus.conflict) {
        return _fail(s, '${peer.name} is pairing with another device');
      }
      if (status != HttpStatus.ok || reply == null) {
        return _fail(s, "couldn't reach ${peer.name}");
      }
      side.onReply(reply);
      s.sid = reply['sid'] as String?;
      final (revealed, _) = await client.pairPost(s.base!, '/v1/pair/reveal', {
        'sid': s.sid,
        ...side.reveal(),
      });
      if (_session != s) return;
      if (revealed != HttpStatus.noContent) {
        return _fail(s, "couldn't pair with ${peer.name}");
      }
      _set(
        PairingStatus(
          PairStep.compare,
          peerName: side.theirName,
          code: side.code,
        ),
      );
    } catch (_) {
      _fail(s, "couldn't pair with ${peer.name}");
    }
  }

  /// What this side's user said about the numbers. On a match, pairing
  /// finishes once the other side's user says so too; on a mismatch it
  /// stops on both.
  Future<void> answer(bool match) async {
    final s = _session;
    if (s == null || _status.step != PairStep.compare) return;
    final name = s.side.theirName;
    s.answer = match;
    if (!match) {
      _refused = s.sid;
      _fail(s, "the numbers didn't match · not paired");
      if (s.side.isInitiator) {
        await _client
            ?.pairPost(s.base!, '/v1/pair/cancel', {'sid': s.sid})
            .catchError((_) => (0, null));
      }
      return;
    }
    _set(PairingStatus(PairStep.waiting, peerName: name, code: s.side.code));
    if (s.side.isInitiator) await _confirm(s);
  }

  /// The initiator's confirm, asked again every second until the other
  /// side's user has answered, or pairing closes.
  Future<void> _confirm(_Session s) async {
    final side = s.side;
    final them = CircleMember(b64(side.theirKey), side.theirName);
    final next = side.provides
        ? (_circle ?? Circle.create(CircleMember(identity.id, _name)))
              .withMember(them)
        : null;
    final box = b64(side.sealConfirm(next));
    while (_session == s) {
      final int status;
      final Map<String, Object?>? reply;
      try {
        (status, reply) = await _client!.pairPost(s.base!, '/v1/pair/confirm', {
          'sid': s.sid,
          'box': box,
        });
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 1));
        continue; // a dropped request; pairing's window bounds the tries
      }
      if (_session != s) return;
      switch (status) {
        case HttpStatus.accepted:
          await Future<void>.delayed(const Duration(seconds: 1));
        case HttpStatus.ok:
          try {
            final theirs = side.openConfirm(unb64(reply!['box'] as String));
            await _joined(s, next ?? theirs, provided: next != null);
          } catch (_) {
            _fail(s, "couldn't pair with ${side.theirName}");
          }
          return;
        case HttpStatus.forbidden:
          return _fail(s, "the numbers didn't match · not paired");
        default:
          return _fail(s, "couldn't pair with ${side.theirName}");
      }
    }
  }

  /// Both said the numbers match: [circle] is the pair's circle now.
  /// When this side [provided] it, the members already in it are told.
  Future<void> _joined(
    _Session s,
    Circle? circle, {
    required bool provided,
  }) async {
    final side = s.side;
    if (circle == null ||
        !circle.has(identity.id) ||
        !circle.has(b64(side.theirKey))) {
      return _fail(s, "couldn't pair with ${side.theirName}");
    }
    final before = _circle;
    _session = null;
    await _adopt(circle);
    _pairingTimer?.cancel();
    _pairingUntil = null;
    _set(
      PairingStatus(
        PairStep.done,
        peerName: side.theirName,
        message: 'paired with ${side.theirName}',
      ),
    );
    if (provided && before != null) {
      unawaited(_push(circle, before, skip: {b64(side.theirKey)}));
    }
  }

  Future<void> _adopt(Circle c) async {
    final keyChanged = _circle?.key == null || !sameBytes(_circle!.key, c.key);
    _circle = c;
    if (keyChanged) _guard = RequestGuard(c.authKey);
    _changed();
    await _persist().catchError((_) {});
  }

  // -------------------------------------------------------------------------
  // Forgetting and leaving.

  /// Takes [publicKey] out of the circle under a new key, which goes to
  /// every other member this device can reach now, sealed to each one's
  /// own key, so the forgotten device cannot read it even if it is
  /// listening. Returns the members it could not reach: they keep the old
  /// key, see nobody, and have to be paired again.
  Future<List<CircleMember>> forget(String publicKey) async {
    final old = _circle;
    if (old == null || publicKey == identity.id) return const [];
    final next = old.without(publicKey);
    final reached = await _push(next, old);
    await _adopt(next);
    return [
      for (final m in next.members)
        if (m.publicKey != identity.id && !reached.contains(m.publicKey)) m,
    ];
  }

  /// Leaves the circle: the members this device can reach take it off
  /// their lists, and private mode goes off here. They keep the key, which
  /// this device still knows; one of them forgetting it would change that,
  /// but one that leaves on its own is taken at its word.
  Future<void> leave() async {
    final old = _circle;
    if (old == null) return;
    await _eachMember(old, (base, pk) async {
      await _client?.circlePost(base, '/v1/circle/leave', _nodeId, old, {
        'from': identity.id,
      });
      return true;
    });
    _circle = null;
    _guard = null;
    _on = false;
    _changed();
    await _persist().catchError((_) {});
  }

  /// Hands [next] to every member of it this device can reach that is not
  /// in [skip], each sealed to its own key; [under] signs the requests, as
  /// the circle they all still share. Returns whom it reached.
  Future<Set<String>> _push(
    Circle next,
    Circle under, {
    Set<String> skip = const {},
  }) async {
    final json = utf8.encode(jsonEncode(next.toJson()));
    return _eachMember(under, (base, pk) async {
      if (!next.has(pk) || skip.contains(pk)) return false;
      final box = identity.sealFor(unb64(pk), 'circle update', json);
      final status = await _client?.circlePost(
        base,
        '/v1/circle/update',
        _nodeId,
        under,
        {'from': identity.id, 'box': b64(box)},
      );
      return status == HttpStatus.noContent;
    });
  }

  /// Runs [act] once for each node discovery lists that answers
  /// `/v1/circle` as a member of [c] (a public peer, or one in another
  /// circle, does not), with its address and public key; collects the keys
  /// [act] said yes for.
  Future<Set<String>> _eachMember(
    Circle c,
    Future<bool> Function(Uri base, String pk) act,
  ) async {
    final client = _client, engine = _engine;
    if (client == null || engine == null) return {};
    final done = <String>{};
    await Future.wait([
      for (final peer in engine.knownPeers)
        () async {
          for (final base in peer.baseUris) {
            final info = await client.circleInfo(base, _nodeId, c);
            if (info == null) continue;
            final pk = info['pk'];
            if (pk is String && pk != identity.id && c.has(pk)) {
              if (await act(base, pk)) done.add(pk);
            }
            return;
          }
        }(),
    ]);
    return done;
  }

  // -------------------------------------------------------------------------
  // The server's side.

  /// Checks a /v1 request's signature while private mode is on. Returns
  /// the circle it was signed under and its nonce, which seal the answer;
  /// null for one to refuse.
  ({Circle circle, String nonce})? authorize(HttpRequest req) {
    final c = _circle, guard = _guard;
    if (c == null || guard == null) return null;
    final nonce = guard.verify(
      req.headers.value(authHeader),
      method: req.method,
      path: pathOf(req.uri),
      nodeId: req.headers.value(nodeIdHeader) ?? '',
    );
    return nonce == null ? null : (circle: c, nonce: nonce);
  }

  /// Answers /v1/pair and /v1/circle. Pairing routes answer only while
  /// pairing is open; circle routes only to a signed request from a member.
  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    final segs = req.uri.pathSegments;
    try {
      if (segs[1] == 'pair' && segs.length == 3 && req.method == 'POST') {
        if (!pairingOpen) {
          claimBody(req);
          res.statusCode = HttpStatus.notFound;
        } else {
          final body = await _readJson(req);
          if (body == null) {
            res.statusCode = HttpStatus.badRequest;
          } else {
            await _pairRoute(segs[2], body, res);
          }
        }
      } else if (segs[1] == 'circle') {
        await _circleRoute(req, segs.skip(2).toList());
      } else {
        claimBody(req);
        res.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      res.statusCode = HttpStatus.badRequest;
    }
    await res.close();
  }

  /// A small JSON body; null if it is not one, or over 16 KB.
  static Future<Map<String, Object?>?> _readJson(HttpRequest req) async {
    final buf = BytesBuilder(copy: false);
    try {
      await for (final chunk in claimBody(
        req,
      ).timeout(const Duration(seconds: 5))) {
        buf.add(chunk);
        if (buf.length > 16 << 10) return null;
      }
      return (jsonDecode(utf8.decode(buf.takeBytes())) as Map).cast();
    } catch (_) {
      return null;
    }
  }

  void _json(HttpResponse res, Map<String, Object?> body) {
    res
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
  }

  Future<void> _pairRoute(
    String route,
    Map<String, Object?> body,
    HttpResponse res,
  ) async {
    final s = _session;
    final mine = s != null && s.sid != null && body['sid'] == s.sid;
    switch (route) {
      case 'hello':
        if (s != null && !_yields(s, body['pk'])) {
          res.statusCode = HttpStatus.conflict;
          return;
        }
        final side = PairingResponder(
          identity,
          _name,
          hasCircle: _circle != null,
        );
        final Map<String, Object?> reply;
        try {
          reply = side.onHello(body);
        } on PairingException {
          res.statusCode = HttpStatus.badRequest;
          return;
        }
        final next = _session = _Session(side, sid: randomId());
        _set(PairingStatus(PairStep.connecting, peerName: side.theirName));
        _json(res, {'sid': next.sid, ...reply});
      case 'reveal' when mine && !s.side.isInitiator:
        try {
          (s.side as PairingResponder).onReveal(body);
        } on PairingException {
          res.statusCode = HttpStatus.badRequest;
          return _fail(s, "couldn't pair with ${s.side.theirName}");
        }
        res.statusCode = HttpStatus.noContent;
        _set(
          PairingStatus(
            PairStep.compare,
            peerName: s.side.theirName,
            code: s.side.code,
          ),
        );
      case 'confirm' when mine && !s.side.isInitiator:
        await _confirmed(s, body, res);
      case 'cancel' when mine:
        res.statusCode = HttpStatus.noContent;
        _fail(s, "the numbers didn't match on the other device · not paired");
      default:
        // An exchange that has ended, or never was; a finished one answers
        // its last confirm again (see [_Session.doneReply]).
        if (route == 'confirm' && body['sid'] == _refused) {
          res.statusCode = HttpStatus.forbidden;
          return;
        }
        final d = _lastDone;
        if (route == 'confirm' &&
            d != null &&
            d.sid == body['sid'] &&
            d.doneReply != null) {
          return _json(res, {'box': d.doneReply});
        }
        res.statusCode = HttpStatus.notFound;
    }
  }

  _Session? _lastDone;

  /// The exchange this side's user last said no to, whose confirm is
  /// answered 403 so the other side can say why.
  String? _refused;

  /// Whether a session that is going yields to a hello from [theirKey]:
  /// when two devices pick each other at once, the one with the smaller
  /// key answers and the other's own exchange stops.
  bool _yields(_Session s, Object? theirKey) {
    if (!s.side.isInitiator || _status.step != PairStep.connecting) {
      return false;
    }
    if (theirKey is! String || theirKey.compareTo(identity.id) <= 0) {
      return false;
    }
    _session = null;
    return true;
  }

  Future<void> _confirmed(
    _Session s,
    Map<String, Object?> body,
    HttpResponse res,
  ) async {
    switch (s.answer) {
      case null:
        res.statusCode = HttpStatus.accepted;
        return;
      case false:
        res.statusCode = HttpStatus.forbidden;
        return;
      case true:
    }
    final side = s.side;
    final Circle? theirs;
    try {
      theirs = side.openConfirm(unb64(body['box'] as String));
    } catch (_) {
      res.statusCode = HttpStatus.badRequest;
      return _fail(s, "couldn't pair with ${side.theirName}");
    }
    final next = side.provides
        ? (_circle ?? Circle.create(CircleMember(identity.id, _name)))
              .withMember(CircleMember(b64(side.theirKey), side.theirName))
        : theirs;
    s.doneReply = b64(side.sealConfirm(next));
    _lastDone = s;
    _json(res, {'box': s.doneReply});
    await _joined(s, next, provided: side.provides);
  }

  Future<void> _circleRoute(HttpRequest req, List<String> rest) async {
    final res = req.response;
    final ok = authorize(req);
    if (ok == null) {
      claimBody(req);
      res.statusCode = HttpStatus.unauthorized;
      return;
    }
    switch ((req.method, rest)) {
      case ('GET', []):
        final body = utf8.encode(
          jsonEncode({'pk': identity.id, 'epoch': ok.circle.epoch}),
        );
        res
          ..contentLength = sealedLength(body.length)
          ..headers.contentType = ContentType.binary;
        await sealStream(
          Stream.value(body),
          ok.circle.bodyKey,
          responseContext(ok.nonce, req.method, pathOf(req.uri)),
        ).forEach(res.add);
      case ('POST', ['update']):
        final body = await _readJson(req);
        final from = body?['from'];
        if (from is! String || !ok.circle.has(from) || from == identity.id) {
          res.statusCode = HttpStatus.forbidden;
          return;
        }
        final Circle next;
        try {
          next = Circle.fromJson(
            (jsonDecode(
                      utf8.decode(
                        identity.openFrom(
                          unb64(from),
                          'circle update',
                          unb64(body!['box'] as String),
                        ),
                      ),
                    )
                    as Map)
                .cast(),
          );
        } catch (_) {
          res.statusCode = HttpStatus.forbidden;
          return;
        }
        if (next.epoch <= ok.circle.epoch || !next.has(identity.id)) {
          res.statusCode = HttpStatus.conflict;
          return;
        }
        res.statusCode = HttpStatus.noContent;
        await _adopt(next);
      case ('POST', ['leave']):
        final body = await _readJson(req);
        final from = body?['from'];
        res.statusCode = HttpStatus.noContent;
        if (from is String && from != identity.id && ok.circle.has(from)) {
          await _adopt(ok.circle.dropping(from));
        }
      default:
        claimBody(req);
        res.statusCode = HttpStatus.notFound;
    }
  }
}
