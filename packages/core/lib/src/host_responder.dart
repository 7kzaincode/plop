import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Answers mDNS for one host name with this computer's address, for a
/// system whose own responder won't: Windows' DnsServiceRegister publishes
/// a service's SRV record pointing at a host name, but never answers for
/// the name itself, so a phone looking up plop.local hears nothing.
///
/// It speaks the "plop/alias" protocol of lib/alias.dart in the app:
/// [invoke] takes "claim" {ip, gen} and "release", and [onState] reports
/// "won", "conflict" or "lost" for a gen. A claim probes first (RFC 6762
/// 8.1: three queries 250 ms apart) and gives up at the first answer from
/// another computer; once won it announces, answers every query for the
/// name, and gives the name up, with no goodbye, when another computer
/// says it is theirs. Release sends the goodbye (TTL 0).
class HostResponder {
  HostResponder(this.name, {required this.onState, this.port = mdnsPort});

  /// The name answered for, as `plop.local`.
  final String name;
  final void Function(String state, int gen) onState;

  /// 5353; another for tests, which can't share the real one everywhere.
  final int port;

  static const mdnsPort = 5353;
  static final group = InternetAddress('224.0.0.251');
  static const ttl = 120;

  RawDatagramSocket? _socket;
  InternetAddress? _ip;
  int _gen = 0;
  bool _held = false;
  final _timers = <Timer>[];

  bool get held => _held;

  Future<Object?> invoke(String method, [Object? args]) async {
    switch (method) {
      case 'claim':
        final map = args as Map;
        await _claim(map['ip'] as String, map['gen'] as int);
      case 'release':
        await release();
    }
    return null;
  }

  Future<void> _claim(String ip, int gen) async {
    await release();
    _gen = gen;
    final address = InternetAddress.tryParse(ip);
    if (address == null || address.type != InternetAddressType.IPv4) {
      return onState('lost', gen);
    }
    final RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
        // Windows has no SO_REUSEPORT; SO_REUSEADDR there already shares.
        reusePort: !Platform.isWindows,
      );
    } on SocketException {
      return onState('lost', gen);
    }
    if (gen != _gen) {
      socket.close(); // released, or claimed again, while binding
      return;
    }
    _socket = socket;
    _ip = address;
    socket
      ..multicastHops = 255
      // On, so this computer's own lookups are answered too.
      ..multicastLoopback = true;
    try {
      socket.joinMulticast(group, await _interfaceOf(address));
    } on SocketException {
      socket.joinMulticast(group);
    }
    socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d != null) _heard(d, gen);
    });
    // Probe: anyone answering for the name in the next 750 ms has it.
    for (var i = 0; i < 3; i++) {
      _later(Duration(milliseconds: 250 * i), () => _send(_query(), gen));
    }
    _later(const Duration(milliseconds: 750), () {
      if (gen != _gen || _socket == null) return;
      _held = true;
      onState('won', gen);
      _send(_answer(ttl), gen);
      _later(const Duration(seconds: 1), () => _send(_answer(ttl), gen));
    });
  }

  /// Lets the name go: a goodbye if it was held, so caches drop it at once.
  Future<void> release() async {
    _gen++;
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    final socket = _socket;
    _socket = null;
    if (socket == null) return;
    if (_held) {
      try {
        socket.send(_answer(0), group, port);
      } on SocketException {
        // Off the network already: there is no one to tell.
      }
    }
    _held = false;
    socket.close();
  }

  void _heard(Datagram d, int gen) {
    if (gen != _gen) return;
    final m = DnsMessage.parse(d.data);
    if (m == null) return;
    if (!m.response) {
      if (!_held) return;
      final asked = m.questions.any(
        (q) => _isName(q.name) && (q.type == typeA || q.type == typeAny),
      );
      if (!asked) return;
      if (d.port != port) {
        // A one-shot (legacy) query: answer it directly, with its id and
        // question, as a unicast DNS server would.
        _send(_answer(ttl, id: m.id, echo: true), gen, to: d.address, port: d.port);
      } else {
        _send(_answer(ttl), gen);
      }
      return;
    }
    // Its own answers, looped back, are no one else's claim.
    if (d.address == _ip) return;
    final claimed = m.answers.any(
      (r) =>
          _isName(r.name) &&
          r.type == typeA &&
          r.ttl > 0 &&
          !_sameBytes(r.data, _ip!.rawAddress),
    );
    if (!claimed) return;
    // Another computer has it, or got it while this one slept.
    _held = false;
    final socket = _socket;
    _socket = null;
    socket?.close();
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    onState('conflict', gen);
  }

  void _send(Uint8List packet, int gen, {InternetAddress? to, int? port}) {
    if (gen != _gen) return;
    try {
      _socket?.send(packet, to ?? group, port ?? this.port);
    } on SocketException {
      // A send that fails (network gone) is caught up by the next claim.
    }
  }

  void _later(Duration d, void Function() f) => _timers.add(Timer(d, f));

  bool _isName(String n) => n.toLowerCase() == name.toLowerCase();

  Uint8List _query() => (BytesBuilder()
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u16(1))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(encodeName(name))
        ..add(_u16(typeAny))
        // Class IN, answers multicast: a unicast one would go to whichever
        // socket on 5353 the system picks, often not this one.
        ..add(_u16(1)))
      .takeBytes();

  Uint8List _answer(int ttl, {int id = 0, bool echo = false}) {
    final b = BytesBuilder()
      ..add(_u16(id))
      ..add(_u16(0x8400)) // response, authoritative
      ..add(_u16(echo ? 1 : 0))
      ..add(_u16(1))
      ..add(_u16(0))
      ..add(_u16(0));
    if (echo) {
      b
        ..add(encodeName(name))
        ..add(_u16(typeA))
        ..add(_u16(1));
    }
    b
      ..add(encodeName(name))
      ..add(_u16(typeA))
      // Cache-flush: this is the only address for the name. A legacy
      // answer leaves the bit off, as the RFC asks.
      ..add(_u16(echo ? 1 : 0x8001))
      ..add(_u32(ttl))
      ..add(_u16(4))
      ..add(_ip!.rawAddress);
    return b.takeBytes();
  }

  static Future<NetworkInterface?> _interfaceOf(InternetAddress ip) async {
    for (final i in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      if (i.addresses.any((a) => a.address == ip.address)) return i;
    }
    return null;
  }
}

const typeA = 1;
const typeAny = 255;

Uint8List _u16(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v);
Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// `plop.local` as DNS labels.
Uint8List encodeName(String name) {
  final b = BytesBuilder();
  for (final label in name.split('.').where((l) => l.isNotEmpty)) {
    final bytes = label.codeUnits;
    b
      ..addByte(bytes.length)
      ..add(bytes);
  }
  b.addByte(0);
  return b.takeBytes();
}

/// The parts of an mDNS message [HostResponder] reads.
class DnsMessage {
  DnsMessage(this.id, this.response, this.questions, this.answers);

  final int id;
  final bool response;
  final List<({String name, int type})> questions;
  final List<({String name, int type, int ttl, Uint8List data})> answers;

  /// Null for anything malformed.
  static DnsMessage? parse(Uint8List bytes) {
    try {
      final v = ByteData.sublistView(bytes);
      var at = 12;
      final qd = v.getUint16(4), an = v.getUint16(6);
      (String, int) name(int at) {
        final labels = <String>[];
        var end = -1;
        for (var hops = 0; hops < 64; hops++) {
          final len = bytes[at];
          if (len == 0) return (labels.join('.'), end < 0 ? at + 1 : end);
          if (len & 0xc0 == 0xc0) {
            if (end < 0) end = at + 2;
            at = ((len & 0x3f) << 8) | bytes[at + 1];
            continue;
          }
          labels.add(String.fromCharCodes(bytes, at + 1, at + 1 + len));
          at += 1 + len;
        }
        throw const FormatException('name loops');
      }

      final questions = <({String name, int type})>[];
      for (var i = 0; i < qd; i++) {
        final (n, next) = name(at);
        questions.add((name: n, type: v.getUint16(next)));
        at = next + 4;
      }
      final answers = <({String name, int type, int ttl, Uint8List data})>[];
      for (var i = 0; i < an; i++) {
        final (n, next) = name(at);
        final len = v.getUint16(next + 8);
        answers.add((
          name: n,
          type: v.getUint16(next),
          ttl: v.getUint32(next + 4),
          data: Uint8List.sublistView(bytes, next + 10, next + 10 + len),
        ));
        at = next + 10 + len;
      }
      return DnsMessage(
        v.getUint16(0),
        v.getUint16(2) & 0x8000 != 0,
        questions,
        answers,
      );
    } catch (_) {
      return null;
    }
  }
}
