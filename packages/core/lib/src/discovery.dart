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

/// Non-loopback IPv4 addresses of this machine, best first ([rankIPv4s]).
Future<List<String>> localIPv4s() async {
  try {
    final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return rankIPv4s([
      for (final i in ifaces)
        for (final a in i.addresses)
          if (!a.isLoopback) (i.name, a.address),
    ]);
  } catch (_) {
    return [];
  }
}

/// IPv4 addresses, given with their interface's name, ordered so the one
/// another device on the same Wi-Fi most likely reaches comes first: the
/// web shelf's QR code shows only that one. Private LAN ranges on a real
/// interface lead (192.168/16, which nearly every home router hands out,
/// then 10/8, then 172.16/12), then any other address on one; after them
/// what VPNs, VMs, containers and Internet Sharing add, by interface name;
/// then 100.64/10 (carrier-grade NAT, and Tailscale); last 169.254/16,
/// which an interface gives itself when no DHCP server answered. Ties keep
/// the system's order, which lists en0 (a Mac's Wi-Fi) first. dart:io has
/// no route table, so the default route itself cannot be asked for.
List<String> rankIPv4s(List<(String, String)> addrs) {
  int rank((String, String) a) {
    final (iface, ip) = a;
    final o = [for (final p in ip.split('.')) int.tryParse(p) ?? 0];
    if (o.length != 4) return 50;
    if (o[0] == 169 && o[1] == 254) return 40;
    if (o[0] == 100 && o[1] >= 64 && o[1] < 128) return 30;
    if (_virtualIface.hasMatch(iface)) return 20;
    if (o[0] == 192 && o[1] == 168) return 0;
    if (o[0] == 10) return 1;
    if (o[0] == 172 && o[1] >= 16 && o[1] < 32) return 2;
    return 10;
  }

  final ranked = [for (final (i, a) in addrs.indexed) (rank(a), i, a.$2)]
    ..sort((x, y) => x.$1 != y.$1 ? x.$1 - y.$1 : x.$2 - y.$2);
  // With a real network address to offer, the VPN, VM and container ones
  // are left out: no other device can reach them (a Windows PC with WSL
  // offers 172.x on its vEthernet adapter), and a peer that tried one
  // first would wait out a timeout on every poll before the real one.
  // Tailscale's 100.64/10 stays: it reaches the user's own devices on any
  // network.
  final real = ranked.any((r) => r.$1 < 20);
  return [
    for (final r in ranked)
      if (!real || (r.$1 != 20 && r.$1 != 40)) r.$3,
  ];
}

/// Interface names of VPN tunnels, VMs, containers and bridges: Unix names
/// by prefix, Windows' friendly names by what they contain.
final _virtualIface = RegExp(
  r'^(utun|tun|tap|ppp|ipsec|gif|stf|awdl|llw|bridge|vmnet|vboxnet|docker|'
  r'br-|veth|virbr|vnic|zt|tailscale|wg|lxc|lxd|cni|flannel|podman|anpi)|'
  r'virtual|vmware|hyper-v|vethernet|wsl|vpn|zerotier|hamachi|wireguard|'
  r'nordlynx|loopback|tap-windows|docker|tailscale',
  caseSensitive: false,
);

/// Whether [name] resolves, through this machine's own resolver, to one
/// of [ips]: on Linux that means avahi and nss-mdns are running, so the
/// `.local` name is being answered for on the network too.
Future<bool> resolvesToSelf(String name, List<String> ips) async {
  try {
    final found = await InternetAddress.lookup(
      name,
      type: InternetAddressType.IPv4,
    ).timeout(const Duration(seconds: 2));
    return found.any((a) => ips.contains(a.address));
  } catch (_) {
    return false;
  }
}
