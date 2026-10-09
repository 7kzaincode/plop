import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plop/grab.dart';
import 'package:plop/settings.dart';
import 'package:plop/settings_panel.dart';
import 'package:plop_core/plop_core.dart';

void main() {
  late Map<String, Object?> alone, paired;

  // Keys are made outside the widget tests' fake clock.
  setUpAll(() async {
    final self = await DeviceIdentity.generate();
    final other = await DeviceIdentity.generate();
    alone = {'identity': self.toJson()};
    paired = {
      'identity': self.toJson(),
      'circle': Circle.create(CircleMember(self.id, 'mac'))
          .withMember(CircleMember(other.id, 'pixel'))
          .toJson(),
      'on': false,
    };
  });

  Future<PrivateMode> load(
    WidgetTester tester,
    Map<String, Object?> json,
  ) async => (await tester.runAsync(() => PrivateMode.load(json)))!;

  /// Opens the panel with [mode] as its private mode, as on a phone (no
  /// shortcuts, no tray).
  Future<void> open(WidgetTester tester, PrivateMode mode) async {
    debugDesktopOverride = false;
    addTearDown(() => debugDesktopOverride = null);
    tester.view
      ..physicalSize = const Size(800, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showSettings(context, Settings.inMemory(), private: mode),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.tapAt(const Offset(5, 5)); // the barrier
    await tester.pumpAndSettle();
  }

  Finder toggle({required bool enabled}) => find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        w.properties.label == 'private mode' &&
        w.properties.enabled == enabled,
  );

  testWidgets('alone: the switch waits for a paired device', (tester) async {
    final mode = await load(tester, alone);
    await open(tester, mode);
    expect(
      find.text('private mode · only your paired devices'),
      findsOneWidget,
    );
    expect(toggle(enabled: false), findsOneWidget);
    expect(find.text('pair a device first'), findsOneWidget);
    expect(find.text('pair a device'), findsOneWidget);
    expect(find.text('leave circle'), findsNothing);
    expect(find.text('forget'), findsNothing);
    await close(tester);
  });

  testWidgets('pair a device opens pairing, closing the panel ends it', (
    tester,
  ) async {
    final mode = await load(tester, alone);
    await open(tester, mode);
    await tester.tap(find.text('pair a device'));
    await tester.pump();
    expect(mode.pairingOpen, isTrue);
    expect(find.textContaining('pairing · 2:00'), findsOneWidget);
    expect(find.text('looking for devices…'), findsOneWidget);
    await close(tester);
    expect(mode.pairingOpen, isFalse);
  });

  testWidgets('pairing runs out after two minutes and says so', (tester) async {
    final mode = await load(tester, alone);
    await open(tester, mode);
    await tester.tap(find.text('pair a device'));
    await tester.pump();
    mode.debugShow(const PairingStatus(PairStep.connecting, peerName: 'pixel'));
    await tester.pump();
    expect(find.text('reaching pixel…'), findsOneWidget);
    await tester.pump(const Duration(minutes: 2, seconds: 1));
    expect(find.text('pairing timed out'), findsOneWidget);
    expect(find.text('pair a device'), findsOneWidget);
    await close(tester);
  });

  testWidgets('the number is big, with match and doesn\'t match', (
    tester,
  ) async {
    final mode = await load(tester, alone);
    await open(tester, mode);
    await tester.tap(find.text('pair a device'));
    await tester.pump();
    mode.debugShow(
      const PairingStatus(PairStep.compare, peerName: 'pixel', code: '042137'),
    );
    await tester.pump();
    final code = tester.widget<Text>(
      find.byKey(const ValueKey('pairing code')),
    );
    expect(code.data, '042 137');
    expect(code.style!.fontSize, greaterThanOrEqualTo(30));
    expect(code.style!.fontFamily, 'GeistMono');
    expect(find.text('same number on pixel?'), findsOneWidget);
    expect(find.text('match'), findsOneWidget);
    expect(find.text("doesn't match"), findsOneWidget);
    mode.debugShow(
      const PairingStatus(PairStep.waiting, peerName: 'pixel', code: '042137'),
    );
    await tester.pump();
    expect(find.text('waiting for pixel to tap match…'), findsOneWidget);
    mode.debugShow(
      const PairingStatus(
        PairStep.done,
        peerName: 'pixel',
        message: 'paired with pixel',
      ),
    );
    mode.closePairing();
    await tester.pump();
    expect(find.text('paired with pixel'), findsOneWidget);
    await close(tester);
  });

  testWidgets('paired: devices with forget, leave, and the switch works', (
    tester,
  ) async {
    final mode = await load(tester, paired);
    await open(tester, mode);
    expect(toggle(enabled: true), findsOneWidget);
    expect(find.text('pixel'), findsOneWidget);
    expect(find.text('forget'), findsOneWidget);
    expect(find.text('leave circle'), findsOneWidget);
    expect(find.text('pair a device first'), findsNothing);
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'private mode',
      ),
    );
    await tester.pump();
    expect(mode.on, isTrue);
    expect(find.textContaining('sealed end to end'), findsOneWidget);
    await close(tester);
  });

  testWidgets('forget with nobody around says who missed the new key', (
    tester,
  ) async {
    final mode = await load(tester, {
      ...paired,
      'circle': Circle.fromJson((paired['circle']! as Map).cast())
          .withMember(const CircleMember('third', 'ipad'))
          .toJson(),
    });
    await open(tester, mode);
    await tester.tap(find.text('forget').first);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(
      find.textContaining("wasn't around for the new key"),
      findsOneWidget,
    );
    expect(mode.others, hasLength(1));
    await close(tester);
  });

  testWidgets('leave circle turns private mode off', (tester) async {
    final mode = await load(tester, {...paired, 'on': true});
    expect(mode.on, isTrue);
    await open(tester, mode);
    await tester.tap(find.text('leave circle'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(mode.on, isFalse);
    expect(mode.circle, isNull);
    expect(find.text('left the circle · private mode is off'), findsOneWidget);
    expect(find.text('pair a device first'), findsOneWidget);
    await close(tester);
  });
}
