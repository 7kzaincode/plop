@TestOn('windows')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:plop_core/plop_core.dart';
import 'package:test/test.dart';

// On a real Windows machine, on the real port: Windows' own DNS Client
// service holds UDP 5353 too, and plop.local on Windows rests on sharing it
// (lib/src/host_responder.dart). Run in CI's Windows job.
void main() {
  test('shares 5353 with Windows and answers a lookup there', () async {
    final name = 'plop-ci-$pid.local';
    final ip = (await localIPv4s()).first;
    final states = <String>[];
    final r = HostResponder(name, onState: (s, _) => states.add(s));
    addTearDown(r.release);
    await r.invoke('claim', {'ip': ip, 'gen': 1});
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(states, ['won'], reason: '"lost" means 5353 could not be shared');

    final asker = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(asker.close);
    final got = Completer<DnsMessage>();
    asker.listen((_) {
      final d = asker.receive();
      final m = d == null ? null : DnsMessage.parse(d.data);
      if (m != null && m.response && !got.isCompleted) got.complete(m);
    });
    asker.send(
      (BytesBuilder()
            ..add([0, 9, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
            ..add(encodeName(name))
            ..add([0, 1, 0, 1]))
          .takeBytes(),
      HostResponder.group,
      HostResponder.mdnsPort,
    );
    final m = await got.future.timeout(const Duration(seconds: 5));
    expect(m.answers.single.data, InternetAddress(ip).rawAddress);

    // What Windows' own resolver makes of it, for the log: the lookup a
    // browser on this PC would do.
    final resolved = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Resolve-DnsName -Name $name -Type A -ErrorAction SilentlyContinue '
          '| Select-Object -ExpandProperty IPAddress',
    ]);
    print('Windows resolver: ${(resolved.stdout as String).trim()}');
  });
}
