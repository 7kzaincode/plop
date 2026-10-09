import 'package:bonsoir/bonsoir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plop/bonsoir_discovery.dart';
import 'package:plop_core/plop_core.dart';

void main() {
  BonsoirService found(String name) =>
      BonsoirService(name: name, type: serviceType, port: 0);

  BonsoirService resolved(String name, {int port = 7567}) => BonsoirService(
    name: name,
    type: serviceType,
    port: port,
    hostAddresses: const ['192.168.1.20'],
    attributes: {'id': 'id-$name', 'v': '1', 'name': name, 'ips': ''},
  );

  // Timers run on the test's fake clock, which pump moves on.
  testWidgets('a failed resolve is asked again, a few times, further apart', (
    tester,
  ) async {
    final d = BonsoirPeerDiscovery();
    final asked = <String>[];
    void resolve(BonsoirService s) => asked.add(s.name);
    const failed = BonsoirDiscoveryServiceResolveFailedEvent();

    d.handle(BonsoirDiscoveryServiceFoundEvent(service: found('mac')), resolve);
    expect(asked, ['mac']);
    for (final (i, wait) in [2, 4, 8].indexed) {
      d.handle(failed, resolve);
      // A second failure while one retry waits does not add another.
      d.handle(failed, resolve);
      await tester.pump(Duration(seconds: wait - 1));
      expect(asked, hasLength(i + 1), reason: 'not before ${wait}s');
      await tester.pump(const Duration(seconds: 1));
    }
    expect(asked, ['mac', 'mac', 'mac', 'mac']);
    d.handle(failed, resolve);
    await tester.pump(const Duration(seconds: 30));
    expect(asked, hasLength(1 + BonsoirPeerDiscovery.maxResolveRetries));
  });

  testWidgets('a resolved peer comes up once it has a port, and is let be', (
    tester,
  ) async {
    final d = BonsoirPeerDiscovery();
    final events = <PeerEvent>[];
    final sub = d.events.listen(events.add);
    addTearDown(sub.cancel);
    final asked = <String>[];
    void resolve(BonsoirService s) => asked.add(s.name);

    d.handle(BonsoirDiscoveryServiceFoundEvent(service: found('mac')), resolve);
    // Android's TXT record comes first, as an update with no port yet.
    d.handle(
      BonsoirDiscoveryServiceUpdatedEvent(service: resolved('mac', port: 0)),
      resolve,
    );
    await tester.pump();
    expect(events, isEmpty);

    d.handle(
      BonsoirDiscoveryServiceResolvedEvent(service: resolved('mac')),
      resolve,
    );
    await tester.pump();
    expect(events.single, isA<PeerUp>());
    expect((events.single as PeerUp).peer.port, 7567);

    // Another service's failure asks nothing more of this one.
    d.handle(const BonsoirDiscoveryServiceResolveFailedEvent(), resolve);
    await tester.pump(const Duration(seconds: 30));
    expect(asked, ['mac']);

    // Gone, and found again: a fresh set of retries.
    d.handle(BonsoirDiscoveryServiceLostEvent(service: found('mac')), resolve);
    await tester.pump();
    expect(events.last, isA<PeerDown>());
    d.handle(BonsoirDiscoveryServiceFoundEvent(service: found('mac')), resolve);
    d.handle(const BonsoirDiscoveryServiceResolveFailedEvent(), resolve);
    await tester.pump(const Duration(seconds: 2));
    expect(asked, ['mac', 'mac', 'mac']);
    await d.stop();
  });

  testWidgets('a service lost while it waits is not asked about again', (
    tester,
  ) async {
    final d = BonsoirPeerDiscovery();
    final asked = <String>[];
    void resolve(BonsoirService s) => asked.add(s.name);
    d.handle(BonsoirDiscoveryServiceFoundEvent(service: found('pc')), resolve);
    d.handle(const BonsoirDiscoveryServiceResolveFailedEvent(), resolve);
    d.handle(BonsoirDiscoveryServiceLostEvent(service: found('pc')), resolve);
    await tester.pump(const Duration(seconds: 30));
    expect(asked, ['pc']);
  });

  testWidgets('private peers carry their hint; a renamed service stays up', (
    tester,
  ) async {
    final d = BonsoirPeerDiscovery();
    final events = <PeerEvent>[];
    final sub = d.events.listen(events.add);
    addTearDown(sub.cancel);
    void resolve(BonsoirService s) {}
    final private = BonsoirService(
      name: 'plop-01234567',
      type: serviceType,
      port: 7567,
      hostAddresses: const ['192.168.1.20'],
      attributes: {'id': 'id-mac', 'v': privateV, 'c': 'hint', 'ips': ''},
    );
    // The same node, public first, then private under its new name; the
    // public name's loss comes last.
    d.handle(
      BonsoirDiscoveryServiceResolvedEvent(
        service: BonsoirService(
          name: 'mac',
          type: serviceType,
          port: 7567,
          hostAddresses: const ['192.168.1.20'],
          attributes: {'id': 'id-mac', 'v': '1', 'name': 'mac', 'ips': ''},
        ),
      ),
      resolve,
    );
    d.handle(BonsoirDiscoveryServiceResolvedEvent(service: private), resolve);
    d.handle(BonsoirDiscoveryServiceLostEvent(service: found('mac')), resolve);
    await tester.pump();
    expect(events, hasLength(2));
    final up = events.last as PeerUp;
    expect(up.peer.hint, 'hint');
    expect(up.peer.name, '');
    d.handle(BonsoirDiscoveryServiceLostEvent(service: private), resolve);
    await tester.pump();
    expect(events.last, isA<PeerDown>());
  });
}
