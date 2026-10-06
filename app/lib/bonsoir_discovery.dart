import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:plop_core/plop_core.dart';

const serviceType = '_plop._tcp';

/// [PeerDiscovery] over mDNS / Bonjour.
class BonsoirPeerDiscovery implements PeerDiscovery {
  final _events = StreamController<PeerEvent>.broadcast();
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _sub;

  /// Lost events only carry the service name, so remember name -> node id.
  final _idsByName = <String, String>{};
  String? _selfId;

  @override
  Stream<PeerEvent> get events => _events.stream;

  @override
  Future<void> start(LocalNode self) async {
    _selfId = self.id;
    final broadcast = _broadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: self.name,
        type: serviceType,
        port: self.port,
        attributes: {
          'id': self.id,
          'v': '1',
          'name': self.name,
          'ips': self.ips.join(','),
        },
      ),
    );
    await broadcast.initialize();
    await broadcast.start();

    final discovery = _discovery = BonsoirDiscovery(type: serviceType);
    await discovery.initialize();
    _sub = discovery.eventStream!.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent(:final service):
          service.resolve(discovery.serviceResolver);
        case BonsoirDiscoveryServiceResolvedEvent(:final service):
        case BonsoirDiscoveryServiceUpdatedEvent(:final service):
          _onResolved(service);
        case BonsoirDiscoveryServiceLostEvent(:final service):
          final id = _idsByName.remove(service.name);
          if (id != null) _events.add(PeerDown(id));
        default:
          break;
      }
    });
    await discovery.start();
  }

  void _onResolved(BonsoirService s) {
    final a = s.attributes;
    final id = a['id'];
    if (id == null || id == _selfId || a['v'] != '1') return;
    final hosts = orderHosts(s.hostAddresses, (a['ips'] ?? '').split(','));
    if (hosts.isEmpty) return;
    _idsByName[s.name] = id;
    _events.add(
      PeerUp(
        Peer(id: id, name: a['name'] ?? s.name, hosts: hosts, port: s.port),
      ),
    );
  }

  @override
  Future<void> stop() async {
    await _sub?.cancel();
    await _discovery?.stop();
    await _broadcast?.stop();
    await _events.close();
  }
}

/// Resolved IPv4 first, then advertised IPv4, then routable IPv6. Link-local
/// IPv6 is skipped: it needs a scope id that URIs do not carry.
List<String> orderHosts(List<String> resolved, List<String> advertised) {
  final v4 = <String>{}, v6 = <String>{};
  for (final h in [...resolved, ...advertised]) {
    final addr = InternetAddress.tryParse(h.trim());
    if (addr == null || addr.isLoopback) continue;
    if (addr.type == InternetAddressType.IPv4) {
      v4.add(addr.address);
    } else if (!addr.isLinkLocal) {
      v6.add(addr.address);
    }
  }
  return [...v4, ...v6];
}
