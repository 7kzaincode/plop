import 'dart:async';
import 'dart:io';

/// This node, as advertised to the network.
class LocalNode {
  LocalNode({
    required this.id,
    required this.name,
    required this.port,
    required this.ips,
  });

  final String id;
  final String name;
  final int port;

  /// IPv4 addresses, advertised as a fallback when mDNS resolves to an
  /// address that is not usable.
  final List<String> ips;
}

class Peer {
  Peer({
    required this.id,
    required this.name,
    required this.hosts,
    required this.port,
  });

  final String id;
  final String name;

  /// Candidate addresses, best first.
  final List<String> hosts;
  final int port;

  List<Uri> get baseUris => [
    for (final h in hosts) Uri(scheme: 'http', host: h, port: port),
  ];
}

sealed class PeerEvent {}

class PeerUp extends PeerEvent {
  PeerUp(this.peer);
  final Peer peer;
}

class PeerDown extends PeerEvent {
  PeerDown(this.id);
  final String id;
}

/// Finds other nodes and advertises this one. The app backs this with mDNS;
/// tests use [StaticDiscovery].
abstract class PeerDiscovery {
  /// Subscribe before calling [start].
  Stream<PeerEvent> get events;
  Future<void> start(LocalNode self);

  /// Advertises [self] again, after the OS dropped the registration (iOS
  /// does this while the app is suspended). Must not close [events].
  Future<void> rebroadcast(LocalNode self);
  Future<void> stop();
}

/// A fixed peer list, for tests and for manual setups.
class StaticDiscovery implements PeerDiscovery {
  StaticDiscovery([List<Peer> peers = const []]) : _initial = peers;

  final List<Peer> _initial;
  final _events = StreamController<PeerEvent>.broadcast();

  @override
  Stream<PeerEvent> get events => _events.stream;

  @override
  Future<void> start(LocalNode self) async {
    for (final p in _initial) {
      _events.add(PeerUp(p));
    }
  }

  void add(Peer p) => _events.add(PeerUp(p));
  void remove(String id) => _events.add(PeerDown(id));

  @override
  Future<void> rebroadcast(LocalNode self) async {}

  @override
  Future<void> stop() => _events.close();
}

/// The name mDNS answers for on this machine, without `.local`. On a Mac
/// the OS host name follows the router's reverse DNS when there is one
/// ("MacBookPro" on one home network) while Bonjour answers for the local
/// host name from the Sharing settings, which `scutil` reads; elsewhere
/// the two are one, bar a domain some networks hand out with it.
Future<String> localHostName() async {
  var name = Platform.localHostname;
  if (Platform.isMacOS) {
    try {
      final r = await Process.run('/usr/sbin/scutil', [
        '--get',
        'LocalHostName',
      ]);
      final local = (r.stdout as String).trim();
      if (r.exitCode == 0 && local.isNotEmpty) name = local;
    } catch (_) {
      // Not there (which would be a surprise): the OS name will do.
    }
  }
  return name.split('.').first.toLowerCase();
}

/// Non-loopback IPv4 addresses of this machine.
Future<List<String>> localIPv4s() async {
  try {
    final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return [
      for (final i in ifaces)
        for (final a in i.addresses)
          if (!a.isLoopback) a.address,
    ];
  } catch (_) {
    return [];
  }
}
