import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:plop_core/plop_core.dart';
import 'package:test/test.dart';

void main() {
  test('encodes and parses a name, a question and an answer', () {
    final name = encodeName('plop.local');
    expect(name, [4, ...'plop'.codeUnits, 5, ...'local'.codeUnits, 0]);
    final packet = (BytesBuilder()
          ..add([0, 7, 0x84, 0, 0, 1, 0, 1, 0, 0, 0, 0])
          ..add(name)
          ..add([0, 1, 0, 1])
          // the answer's name as a pointer back to the question's (offset 12)
          ..add([0xc0, 12, 0, 1, 0x80, 1, 0, 0, 0, 120, 0, 4, 10, 0, 0, 2]))
        .takeBytes();
    final m = DnsMessage.parse(packet)!;
    expect(m.id, 7);
    expect(m.response, isTrue);
    expect(m.questions.single, (name: 'plop.local', type: typeA));
    final a = m.answers.single;
    expect(a.name, 'plop.local');
    expect(a.type, typeA);
    expect(a.ttl, 120);
    expect(a.data, [10, 0, 0, 2]);
    expect(DnsMessage.parse(Uint8List.fromList([1, 2, 3])), isNull);
  });

  // Two responders on one machine, on a port of their own, stand in for two
  // computers: the second hears the first's answer to its probe.
  test('a claim is won when no one answers, and lost to a holder', () async {
    const port = 53537;
    final states = <String>[];
    final a = HostResponder(
      'plop-test.local',
      port: port,
      onState: (s, _) => states.add('a $s'),
    );
    final b = HostResponder(
      'plop-test.local',
      port: port,
      onState: (s, _) => states.add('b $s'),
    );
    addTearDown(() async {
      await a.release();
      await b.release();
    });
    await a.invoke('claim', {'ip': '10.0.0.1', 'gen': 1});
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(states, ['a won']);
    expect(a.held, isTrue);

    await b.invoke('claim', {'ip': '10.0.0.2', 'gen': 1});
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(states, ['a won', 'b conflict']);
    expect(b.held, isFalse);
    expect(a.held, isTrue, reason: 'the holder keeps it');
  }, skip: Platform.isWindows ? 'no shared multicast port in CI' : null);

  test('a one-shot lookup is answered directly, with its own id', () async {
    const port = 53538;
    final r = HostResponder('plop-test.local', port: port, onState: (_, _) {});
    addTearDown(r.release);
    await r.invoke('claim', {'ip': '10.0.0.3', 'gen': 1});
    await Future<void>.delayed(const Duration(milliseconds: 1000));

    final asker = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(asker.close);
    final got = Completer<DnsMessage>();
    asker.listen((e) {
      final d = asker.receive();
      final m = d == null ? null : DnsMessage.parse(d.data);
      if (m != null && m.response && !got.isCompleted) got.complete(m);
    });
    asker.send(
      (BytesBuilder()
            ..add([0x12, 0x34, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0])
            ..add(encodeName('PLOP-test.local'))
            ..add([0, 1, 0, 1]))
          .takeBytes(),
      HostResponder.group,
      port,
    );
    final m = await got.future.timeout(const Duration(seconds: 3));
    expect(m.id, 0x1234);
    expect(m.answers.single.data, [10, 0, 0, 3]);
  }, skip: Platform.isWindows ? 'no shared multicast port in CI' : null);
}
