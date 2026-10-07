import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
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

  /// Services found and not resolved yet, by name. A failed resolve does
  /// not say which service it was (bonsoir 7 drops it), so each failure
  /// asks again for all of these, a few times, further apart each time.
  /// Without that, a peer whose one resolve failed (Android's NsdManager
  /// is prone to it) stayed missing until mDNS announced it afresh, which
  /// for a device that stays up can be never.
  final _unresolved = <String, BonsoirService>{};
  final _retries = <String, int>{};
  final _retryTimers = <String, Timer>{};

  /// Times a found service is asked to resolve again, 2, 4 and 8 s after a
  /// failure.
  static const maxResolveRetries = 3;

  @override
  Stream<PeerEvent> get events => _events.stream;

  @override
  Future<void> start(LocalNode self) async {
    _selfId = self.id;
    await _advertise(self);

    final discovery = _discovery = BonsoirDiscovery(type: serviceType);
    await discovery.initialize();
    _sub = discovery.eventStream!.listen(
      (event) =>
          handle(event, (s) => s.resolve(discovery.serviceResolver).ignore()),
    );
    await discovery.start();
  }

  /// One event from discovery; [resolve] asks the platform to resolve a
  /// found service. Tests drive it with made-up events.
  @visibleForTesting
  void handle(
    BonsoirDiscoveryEvent event,
    void Function(BonsoirService service) resolve,
  ) {
    switch (event) {
      case BonsoirDiscoveryServiceFoundEvent(:final service):
        _unresolved[service.name] = service;
        resolve(service);
      case BonsoirDiscoveryServiceResolvedEvent(:final service):
      case BonsoirDiscoveryServiceUpdatedEvent(:final service):
        _onResolved(service);
      case BonsoirDiscoveryServiceResolveFailedEvent():
        for (final s in [..._unresolved.values]) {
          _retry(s, resolve);
        }
      case BonsoirDiscoveryServiceLostEvent(:final service):
        _forget(service.name);
        final id = _idsByName.remove(service.name);
        if (id != null) _events.add(PeerDown(id));
      default:
        break;
    }
  }

  /// Asks for [s] to be resolved again after a while, unless that is
  /// already on its way or it has been asked [maxResolveRetries] times.
  void _retry(BonsoirService s, void Function(BonsoirService) resolve) {
    if (_retryTimers.containsKey(s.name)) return;
    final n = (_retries[s.name] ?? 0) + 1;
    if (n > maxResolveRetries) return;
    _retries[s.name] = n;
    _retryTimers[s.name] = Timer(Duration(seconds: 1 << n), () {
      _retryTimers.remove(s.name);
      if (_unresolved[s.name] case final found?) resolve(found);
    });
  }

  /// [name] resolved or left: nothing more to ask about it.
  void _forget(String name) {
    _unresolved.remove(name);
    _retries.remove(name);
    _retryTimers.remove(name)?.cancel();
  }

  Future<void> _advertise(LocalNode self) async {
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
  }

  /// iOS drops the registration while the app is suspended; register again
  /// with the current port. Discovery is left alone so peer state survives.
  @override
  Future<void> rebroadcast(LocalNode self) async {
    try {
      await _broadcast?.stop();
    } catch (_) {
      // Already gone.
    }
    await _advertise(self);
  }

  void _onResolved(BonsoirService s) {
    // Android and Linux hand over the TXT record as an update before the
    // service resolves, with no port yet: nothing to connect to, and its
    // resolve may still fail.
    if (s.port == 0) return;
    _forget(s.name);
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
    for (final t in _retryTimers.values) {
      t.cancel();
    }
    _retryTimers.clear();
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
