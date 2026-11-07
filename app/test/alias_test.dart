import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plop/alias.dart';

/// The runner's side of "plop/alias", as a log of what it was asked.
class FakeRunner {
  final calls = <(String, Object?)>[];
  bool missing = false;

  Future<Object?> invoke(String method, [Object? args]) async {
    if (missing) throw MissingPluginException();
    calls.add((method, args));
    return null;
  }

  List<String> get methods => [for (final c in calls) c.$1];
  Map<Object?, Object?> get lastClaim =>
      calls.lastWhere((c) => c.$1 == 'claim').$2! as Map<Object?, Object?>;
}

void main() {
  late FakeRunner runner;
  late String? ip;
  late Alias alias;

  void say(String state, [int? gen]) => alias
      .handle(
        MethodCall('state', {
          'state': state,
          'gen': gen ?? runner.lastClaim['gen'],
        }),
      )
      .ignore();

  setUp(() {
    runner = FakeRunner();
    ip = '192.168.1.5';
    alias = Alias(
      invoke: runner.invoke,
      address: () async => ip,
      random: Random(1),
    );
  });

  test('claims the top address and holds the name once won', () {
    fakeAsync((t) {
      alias.want(true);
      t.flushMicrotasks();
      expect(runner.methods, ['claim']);
      expect(runner.lastClaim['ip'], '192.168.1.5');
      expect(alias.state, AliasState.claiming);
      say('won');
      t.flushMicrotasks();
      expect(alias.held, isTrue);
      // Held, nothing more is asked for while the address stays.
      t.elapse(const Duration(minutes: 5));
      expect(runner.methods, ['claim']);
    });
  });

  test('a conflict lets go, never renames, and asks again after 8-14 s', () {
    fakeAsync((t) {
      alias.want(true);
      t.flushMicrotasks();
      say('conflict');
      t.flushMicrotasks();
      expect(alias.state, AliasState.waiting);
      expect(runner.methods, ['claim', 'release']);
      t.elapse(const Duration(seconds: 7));
      expect(runner.methods, ['claim', 'release'], reason: 'not before 8 s');
      t.elapse(const Duration(seconds: 7));
      expect(runner.methods, ['claim', 'release', 'claim']);
      // Every claim is for the same name and address, only a new gen.
      expect(runner.lastClaim['ip'], '192.168.1.5');
      expect(runner.lastClaim.keys.toSet(), {'ip', 'gen'});
      // Still taken: again, and again, until the holder goes.
      say('conflict');
      t.elapse(const Duration(seconds: 30));
      expect(runner.methods.where((m) => m == 'claim'), hasLength(3));
      say('won');
      t.flushMicrotasks();
      expect(alias.held, isTrue);
    });
  });

  test('the wait is jittered between 8 and 14 s', () {
    for (var seed = 0; seed < 20; seed++) {
      fakeAsync((t) {
        final r = FakeRunner();
        final a = Alias(
          invoke: r.invoke,
          address: () async => '10.0.0.2',
          random: Random(seed),
        );
        a.want(true);
        t.flushMicrotasks();
        a.handle(
          MethodCall('state', {'state': 'lost', 'gen': r.lastClaim['gen']}),
        );
        t.flushMicrotasks();
        var waited = Duration.zero;
        while (r.methods.where((m) => m == 'claim').length < 2) {
          t.elapse(const Duration(milliseconds: 100));
          waited += const Duration(milliseconds: 100);
        }
        expect(waited, greaterThanOrEqualTo(Alias.retry));
        expect(waited, lessThanOrEqualTo(Alias.retry + Alias.jitter));
      });
    }
  });

  test('a state for an older claim is ignored', () {
    fakeAsync((t) {
      alias.want(true);
      t.flushMicrotasks();
      final old = runner.lastClaim['gen']! as int;
      say('conflict');
      t.elapse(const Duration(seconds: 30));
      say('won', old);
      t.flushMicrotasks();
      expect(alias.held, isFalse);
      say('won');
      t.flushMicrotasks();
      expect(alias.held, isTrue);
    });
  });

  test('a new address (a wake, another network) is claimed afresh', () {
    fakeAsync((t) {
      alias.want(true);
      t.flushMicrotasks();
      say('won');
      t.flushMicrotasks();
      ip = '10.0.0.7';
      t.elapse(Alias.recheck);
      expect(runner.methods, ['claim', 'release', 'claim']);
      expect(runner.lastClaim['ip'], '10.0.0.7');
      expect(alias.state, AliasState.claiming);
      // Off the network: nothing to claim, so it waits and tries later.
      say('won');
      t.flushMicrotasks();
      ip = null;
      t.elapse(Alias.recheck);
      expect(alias.state, AliasState.waiting);
      ip = '10.0.0.8';
      t.elapse(Alias.retry + Alias.jitter);
      expect(runner.lastClaim['ip'], '10.0.0.8');
    });
  });

  test('release lets go and stops retrying; off twice asks nothing', () {
    fakeAsync((t) {
      alias.want(true);
      t.flushMicrotasks();
      say('conflict');
      t.flushMicrotasks();
      alias.want(false);
      t.flushMicrotasks();
      expect(alias.state, AliasState.off);
      expect(runner.methods, ['claim', 'release', 'release']);
      t.elapse(const Duration(minutes: 2));
      expect(runner.methods, ['claim', 'release', 'release']);
      alias.want(false);
      alias.release();
      t.flushMicrotasks();
      expect(runner.methods, hasLength(3));
      // A late answer to the released claim changes nothing.
      say('won');
      t.flushMicrotasks();
      expect(alias.state, AliasState.off);
    });
  });

  test('release never holds a quit up for long', () {
    fakeAsync((t) {
      final slow = Alias(
        invoke: (m, [a]) => m == 'release'
            ? Future<void>.delayed(const Duration(minutes: 1))
            : Future.value(),
        address: () async => '192.168.1.5',
      );
      slow.want(true);
      t.flushMicrotasks();
      var done = false;
      slow.release().then((_) => done = true);
      t.elapse(Alias.releaseBudget);
      expect(done, isTrue);
    });
  });

  test('no runner, or no way to claim names: unavailable, no retries', () {
    fakeAsync((t) {
      runner.missing = true;
      alias.want(true);
      t.flushMicrotasks();
      expect(alias.state, AliasState.unavailable);
      runner.missing = false;
      t.elapse(const Duration(minutes: 2));
      expect(runner.calls, isEmpty);
    });
    fakeAsync((t) {
      final r = FakeRunner();
      final a = Alias(invoke: r.invoke, address: () async => '10.0.0.2');
      a.want(true);
      t.flushMicrotasks();
      a.handle(
        MethodCall('state', {
          'state': 'unavailable',
          'gen': r.lastClaim['gen'],
        }),
      );
      t.elapse(const Duration(minutes: 2));
      expect(a.state, AliasState.unavailable);
      expect(r.methods, ['claim']);
    });
  });
}
