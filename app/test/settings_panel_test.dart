import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plop/grab.dart';
import 'package:plop/hotkeys.dart';
import 'package:plop/settings.dart';
import 'package:plop/settings_panel.dart';

void main() {
  /// Opens the panel as on desktop.
  Future<Settings> openPanel(WidgetTester tester, {Settings? settings}) async {
    debugDesktopOverride = true;
    addTearDown(() => debugDesktopOverride = null);
    // No plugin in the test runner: answer the (un)register calls quietly.
    const hotkeys = MethodChannel('dev.leanflutter.plugins/hotkey_manager');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(hotkeys, (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(hotkeys, null));
    final s = settings ?? Settings.inMemory();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettings(context, s),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return s;
  }

  /// Opens the panel and starts recording the snip shortcut.
  Future<Settings> startRecording(
    WidgetTester tester, {
    Settings? settings,
  }) async {
    final s = await openPanel(tester, settings: settings);
    await tester.tap(find.text(Hotkeys.snipLabel));
    await tester.pump();
    expect(find.text('…'), findsOneWidget);
    return s;
  }

  Finder toggled(bool on) => find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.toggled == on,
  );

  testWidgets('the login toggle flips when the platform agrees', (
    tester,
  ) async {
    // Stand in for the Swift side: remember the setting and report it.
    const window = MethodChannel('plop/window');
    final messenger = tester.binding.defaultBinaryMessenger;
    var on = false;
    messenger.setMockMethodCallHandler(window, (call) async {
      if (call.method == 'setLoginItem') on = call.arguments as bool;
      return on;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(window, null));
    await openPanel(tester);
    expect(toggled(false), findsOneWidget);

    await tester.tap(toggled(false));
    await tester.pumpAndSettle();
    expect(toggled(true), findsOneWidget);
    expect(on, isTrue);
    expect(find.textContaining("couldn't change"), findsNothing);
  }, skip: !Platform.isMacOS); // elsewhere the toggle would edit the real OS

  testWidgets('a Shift-only combo is refused and recording goes on', (
    tester,
  ) async {
    final settings = await startRecording(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(find.text('…'), findsOneWidget, reason: 'still recording');
    expect(find.textContaining('everywhere'), findsOneWidget);
    expect(Hotkeys.same(Hotkeys.snip, Hotkeys.defaultSnip), isTrue);
    expect(settings.hotkey('snip'), isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('…'), findsNothing);
    expect(find.text(Hotkeys.snipLabel), findsOneWidget);
  });

  testWidgets('recording a shortcut shows it right away', (tester) async {
    final settings = await startRecording(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(find.text('…'), findsNothing, reason: 'still recording');
    expect(Hotkeys.keyName(Hotkeys.snip.physicalKey), 'S');
    expect(find.text(Hotkeys.label(Hotkeys.snip)), findsOneWidget);

    // It was saved, and reads back as the same binding.
    final saved = settings.hotkey('snip');
    expect(saved, isNotNull);
    expect(Hotkeys.same(saved!, Hotkeys.snip), isTrue);
    Hotkeys.snip = Hotkeys.defaultSnip;
  });

  testWidgets('a shortcut that cannot be saved says so and still works', (
    tester,
  ) async {
    // A settings path under a plain file: creating its directory fails.
    // (Sync IO: an awaited real IO future never resolves under FakeAsync.)
    final dir = Directory.systemTemp.createTempSync('plop_settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final blocker = File('${dir.path}/blocker')..writeAsStringSync('');
    await startRecording(
      tester,
      settings: Settings.at(File('${blocker.path}/settings.json')),
    );

    // Press the keys in real time, so the disk write runs and fails.
    await tester.runAsync(() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(find.textContaining("couldn't save"), findsOneWidget);
    expect(Hotkeys.keyName(Hotkeys.snip.physicalKey), 'S');
    Hotkeys.snip = Hotkeys.defaultSnip;
  });
}
