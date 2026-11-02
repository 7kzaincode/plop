import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:plop/grab.dart';
import 'package:plop/hotkeys.dart';
import 'package:plop/login_item.dart';
import 'package:plop/notify.dart';
import 'package:plop/settings.dart';
import 'package:plop/settings_panel.dart';
import 'package:plop/tray.dart';
import 'package:uni_platform/uni_platform.dart';

void main() {
  /// Opens the panel as on desktop. With [onQuit], the app has the window's
  /// quit key as plop's does, and the panel its "quit plop" link.
  Future<Settings> openPanel(
    WidgetTester tester, {
    Settings? settings,
    VoidCallback? onQuit,
  }) async {
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
        builder: onQuit == null
            ? null
            : (context, child) => QuitKey(onQuit: onQuit, child: child!),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettings(context, s, onQuit: onQuit),
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

  /// The login toggle. Matching on `toggled` alone would also find the
  /// notifications toggle, which is on by default.
  Finder toggled(bool on) => find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        w.properties.label == 'open plop at login' &&
        w.properties.toggled == on,
  );

  /// The note that refuses a bare Enter: it would block typing it, or on
  /// Linux, where keybinder can't bind Enter at all, no shortcut can use it
  /// (Hotkeys.bindable, which goes by uni_platform's idea of the OS).
  Finder refusedEnter() => find.textContaining(
    UniPlatform.isLinux ? "can't be a system-wide" : 'everywhere',
  );

  Finder notifications(bool on) => find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        w.properties.label == 'show arrivals' &&
        w.properties.toggled == on,
  );

  testWidgets('the login toggle flips when the platform agrees', (
    tester,
  ) async {
    // Stand in for the Swift side: remember the setting and report it.
    const window = MethodChannel('plop/window');
    final messenger = tester.binding.defaultBinaryMessenger;
    var on = false;
    messenger.setMockMethodCallHandler(window, (call) async {
      if (call.method == 'loginItem') return on;
      if (call.method == 'setLoginItem') on = call.arguments as bool;
      return on ? 'on' : 'off';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(window, null));
    await openPanel(tester);
    expect(toggled(false), findsOneWidget);

    await tester.tap(toggled(false));
    await tester.pumpAndSettle();
    expect(toggled(true), findsOneWidget);
    expect(on, isTrue);
    expect(find.textContaining("couldn't change"), findsNothing);

    // Tab reaches it, after the three shortcut keys and the reset link;
    // Space flips it back, Enter flips it again.
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    }
    await tester.pump();
    final inside = find.descendant(
      of: toggled(true),
      matching: find.byType(GestureDetector),
    );
    expect(Focus.of(tester.element(inside)).hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(toggled(false), findsOneWidget);
    expect(on, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(toggled(true), findsOneWidget);
    expect(on, isTrue);
  }, skip: !Platform.isMacOS); // elsewhere the toggle would edit the real OS

  // macOS 12 has no SMAppService; the switch is not offered there.
  test('open at login is offered from macOS 13', () {
    expect(
      LoginItem.macHasLoginItems('Version 12.7.6 (Build 21H1320)'),
      isFalse,
    );
    expect(LoginItem.macHasLoginItems('Version 13.4 (Build 22F66)'), isTrue);
    expect(LoginItem.macHasLoginItems('Version 26.0 (Build 25A354)'), isTrue);
    expect(LoginItem.macHasLoginItems('something new'), isTrue);
  });

  testWidgets('a login item macOS holds for approval says where to go', (
    tester,
  ) async {
    // macOS registered it but the user once switched it off in System
    // Settings; the toggle stays off and the note says where to fix it.
    const window = MethodChannel('plop/window');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(window, (call) async {
      if (call.method == 'loginItem') return false;
      return 'needsApproval';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(window, null));
    await openPanel(tester);

    await tester.tap(toggled(false));
    await tester.pumpAndSettle();
    expect(toggled(false), findsOneWidget);
    expect(find.textContaining('approve plop in System Settings'), findsOne);
    expect(find.textContaining("couldn't change"), findsNothing);
  }, skip: !Platform.isMacOS); // elsewhere the toggle would edit the real OS

  testWidgets('the notifications toggle is on by default and remembers off', (
    tester,
  ) async {
    final settings = await openPanel(tester);
    expect(find.text('when plop is in the background'), findsOneWidget);
    expect(notifications(true), findsOneWidget);
    expect(settings.notifications, isTrue);

    await tester.ensureVisible(notifications(true));
    await tester.tap(notifications(true));
    await tester.pumpAndSettle();
    expect(notifications(false), findsOneWidget);
    expect(settings.notifications, isFalse);

    // Reopened, the panel shows what was saved.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(notifications(false), findsOneWidget);
  }, skip: !Notify.supported); // the section is desktop only

  testWidgets('copying arrivals is off by default, says why, remembers on', (
    tester,
  ) async {
    Finder autoCopy(bool on) => find.byWidgetPredicate(
      (w) =>
          w is Semantics &&
          w.properties.label == 'copy arrivals automatically' &&
          w.properties.toggled == on,
    );
    final settings = await openPanel(tester);
    expect(autoCopy(false), findsOneWidget);
    expect(settings.autoCopy, isFalse);
    expect(find.textContaining('anyone nearby can fill it'), findsOneWidget);

    await tester.ensureVisible(autoCopy(false));
    await tester.tap(autoCopy(false));
    await tester.pumpAndSettle();
    expect(autoCopy(true), findsOneWidget);
    expect(settings.autoCopy, isTrue);
    expect(notifications(true), findsOneWidget, reason: 'its own switch');

    // Reopened, the panel shows what was saved.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(autoCopy(true), findsOneWidget);
  }, skip: !Notify.supported); // the section is desktop only

  testWidgets('with the tray icon up on Windows and Linux, the panel quits', (
    tester,
  ) async {
    addTearDown(() {
      Tray.debugActive = null;
      Tray.debugQuitsInWindow = null;
    });
    final link = find.text('quit plop · Ctrl+Q');
    var quits = 0;

    // No icon: closing the window quits, so there is nothing to add.
    Tray.debugActive = false;
    Tray.debugQuitsInWindow = true;
    await openPanel(tester, onQuit: () => quits++);
    expect(link, findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // macOS has ⌘Q.
    Tray.debugActive = true;
    Tray.debugQuitsInWindow = false;
    await openPanel(tester, onQuit: () => quits++);
    expect(link, findsNothing);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    Tray.debugQuitsInWindow = true;
    await openPanel(tester, onQuit: () => quits++);
    await tester.ensureVisible(link);
    await tester.tap(link);
    expect(quits, 1);
  }, skip: !Notify.supported); // the section is desktop only

  testWidgets('Ctrl+Q quits from the window, not while a shortcut records', (
    tester,
  ) async {
    Tray.debugQuitsInWindow = true;
    addTearDown(() => Tray.debugQuitsInWindow = null);
    // The clipboard shortcut on Ctrl+Q, so the recorder refuses it on every
    // host (Windows and Linux refuse it anyway, as an everyday shortcut).
    Hotkeys.clip = HotKey(
      key: PhysicalKeyboardKey.keyQ,
      modifiers: [HotKeyModifier.control],
    );
    addTearDown(() => Hotkeys.clip = Hotkeys.defaultClip);
    Future<void> ctrlQ() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    var quits = 0;
    await openPanel(tester, onQuit: () => quits++);
    await ctrlQ();
    expect(quits, 1, reason: 'the panel open, nothing recording');

    await tester.tap(find.text(Hotkeys.snipLabel));
    await tester.pump();
    expect(find.text('…'), findsOneWidget);
    await ctrlQ();
    expect(quits, 1, reason: 'a key offered to the recorder');
    expect(find.text('…'), findsOneWidget, reason: 'still recording');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await ctrlQ();
    expect(quits, 2);
  });

  testWidgets('Tab reaches the shortcut keys and reset; Enter presses them', (
    tester,
  ) async {
    final settings = await openPanel(tester);
    // The ring is the one bordered box with nothing inside it.
    final ring = find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.child == null &&
          (w.decoration as BoxDecoration).border != null,
    );
    bool focused(Finder f) => Focus.of(tester.element(f)).hasPrimaryFocus;

    // Tab lands on the snip key; Enter starts recording, as a click would.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(focused(find.text(Hotkeys.snipLabel)), isTrue);
    expect(ring, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('…'), findsOneWidget);

    // While recording, Enter is a key being offered, not a press: the
    // recorder refuses it and goes on, rather than starting over.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('…'), findsOneWidget);
    expect(refusedEnter(), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(Hotkeys.keyName(Hotkeys.snip.physicalKey), 'S');
    expect(settings.hotkey('snip'), isNotNull);

    // Tab on to the clipboard and grab keys, then the reset link; Space
    // resets.
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    }
    await tester.pump();
    expect(focused(find.text('reset to defaults')), isTrue);
    expect(ring, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(Hotkeys.same(Hotkeys.snip, Hotkeys.defaultSnip), isTrue);
    expect(settings.hotkey('snip'), isNull);
    expect(find.text(Hotkeys.label(Hotkeys.defaultSnip)), findsOneWidget);
  });

  testWidgets('while recording, Enter on the reset link resets nothing', (
    tester,
  ) async {
    // A binding of its own, so a reset that slipped through would show.
    final own = HotKey(
      key: PhysicalKeyboardKey.keyS,
      modifiers: Hotkeys.defaultMods,
    );
    Hotkeys.clip = own;
    addTearDown(() => Hotkeys.clip = Hotkeys.defaultClip);
    await openPanel(tester);
    bool focused(Finder f) => Focus.of(tester.element(f)).hasPrimaryFocus;

    // Tab to the reset link, then start recording with a click on the snip
    // key. The click takes focus with it, so a bare Enter is offered to the
    // recorder (and refused) rather than pressing the link.
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    }
    await tester.pump();
    expect(focused(find.text('reset to defaults')), isTrue);
    await tester.tap(find.text(Hotkeys.snipLabel));
    await tester.pump();
    expect(find.text('…'), findsOneWidget);
    expect(focused(find.text('…')), isTrue, reason: 'the click took focus');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('…'), findsOneWidget, reason: 'still recording');
    expect(refusedEnter(), findsOneWidget);
    expect(Hotkeys.same(Hotkeys.clip, own), isTrue);
    expect(Hotkeys.same(Hotkeys.snip, Hotkeys.defaultSnip), isTrue);

    // Tab is refused as a binding too, but still moves focus; Enter on the
    // link it reaches is no reset either while the recorder is up.
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    }
    await tester.pump();
    expect(focused(find.text('reset to defaults')), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('…'), findsOneWidget, reason: 'still recording');
    expect(Hotkeys.same(Hotkeys.clip, own), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('…'), findsNothing);
    expect(Hotkeys.same(Hotkeys.clip, own), isTrue);
  });

  testWidgets('while recording, Space on the login toggle flips nothing', (
    tester,
  ) async {
    const window = MethodChannel('plop/window');
    final messenger = tester.binding.defaultBinaryMessenger;
    var sets = 0;
    messenger.setMockMethodCallHandler(window, (call) async {
      if (call.method == 'loginItem') return false;
      if (call.method == 'setLoginItem') sets++;
      return 'on';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(window, null));
    await openPanel(tester);
    final toggle = find.descendant(
      of: toggled(false),
      matching: find.byType(GestureDetector),
    );
    bool focused(Finder f) => Focus.of(tester.element(f)).hasPrimaryFocus;

    // Tab past the keys and the reset link onto the toggle; a click on the
    // clipboard key then starts recording and takes focus with it.
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    }
    await tester.pump();
    expect(focused(toggle), isTrue);
    await tester.tap(find.text(Hotkeys.clipLabel));
    await tester.pump();
    expect(find.text('…'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(sets, 0);
    expect(toggled(false), findsOneWidget);
    expect(find.text('…'), findsOneWidget, reason: 'still recording');

    // Back on the toggle by Tab, Space is still a key being offered.
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    }
    await tester.pump();
    expect(focused(toggle), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(sets, 0);
    expect(toggled(false), findsOneWidget);
    expect(find.text('…'), findsOneWidget, reason: 'still recording');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('…'), findsNothing);
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

  testWidgets(
    'grab the newest has a row of its own, refuses taken keys, resets',
    (tester) async {
      addTearDown(() => Hotkeys.grab = Hotkeys.defaultGrab);
      final settings = await openPanel(tester);
      expect(find.text('grab the newest'), findsOneWidget);
      expect(find.text(Hotkeys.label(Hotkeys.defaultGrab)), findsOneWidget);

      await tester.tap(find.text(Hotkeys.grabLabel));
      await tester.pump();
      expect(find.text('…'), findsOneWidget);

      /// Holds [mods] down and presses [key].
      Future<void> chord(
        List<LogicalKeyboardKey> mods,
        LogicalKeyboardKey key,
      ) async {
        for (final m in mods) {
          await tester.sendKeyDownEvent(m);
        }
        await tester.sendKeyEvent(key);
        for (final m in mods.reversed) {
          await tester.sendKeyUpEvent(m);
        }
        await tester.pump();
      }

      // The snip's own keys: refused, and recording goes on.
      await chord([
        for (final m in Hotkeys.defaultMods)
          switch (m) {
            HotKeyModifier.control => LogicalKeyboardKey.controlLeft,
            HotKeyModifier.shift => LogicalKeyboardKey.shiftLeft,
            _ => LogicalKeyboardKey.altLeft,
          },
      ], LogicalKeyboardKey.keyP);
      expect(find.text('that one is already taken'), findsOneWidget);
      expect(find.text('…'), findsOneWidget, reason: 'still recording');

      await chord([
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.altLeft,
      ], LogicalKeyboardKey.keyS);
      expect(find.text('…'), findsNothing);
      expect(Hotkeys.keyName(Hotkeys.grab.physicalKey), 'S');
      expect(find.text(Hotkeys.grabLabel), findsOneWidget);
      expect(Hotkeys.same(settings.hotkey('grab')!, Hotkeys.grab), isTrue);
      expect(Hotkeys.same(Hotkeys.snip, Hotkeys.defaultSnip), isTrue);
      expect(settings.hotkey('snip'), isNull, reason: 'the others keep theirs');

      await tester.tap(find.text('reset to defaults'));
      await tester.pump();
      expect(Hotkeys.same(Hotkeys.grab, Hotkeys.defaultGrab), isTrue);
      expect(settings.hotkey('grab'), isNull);
      expect(find.text(Hotkeys.label(Hotkeys.defaultGrab)), findsOneWidget);
    },
  );

  testWidgets('a reset that cannot be saved says so', (tester) async {
    addTearDown(() => Hotkeys.snip = Hotkeys.defaultSnip);
    final dir = Directory.systemTemp.createTempSync('plop_settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final blocker = File('${dir.path}/blocker')..writeAsStringSync('');
    Hotkeys.snip = HotKey(
      key: PhysicalKeyboardKey.keyS,
      modifiers: Hotkeys.defaultMods,
    );
    await openPanel(
      tester,
      settings: Settings.at(File('${blocker.path}/settings.json')),
    );

    // Tapped in real time, so the disk writes run and fail.
    await tester.runAsync(() async {
      await tester.tap(find.text('reset to defaults'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(
      find.text("couldn't save that · the defaults hold until plop quits"),
      findsOneWidget,
    );
    expect(Hotkeys.same(Hotkeys.snip, Hotkeys.defaultSnip), isTrue);
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
