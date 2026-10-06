import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plop/grab.dart';
import 'package:plop/hotkeys.dart';
import 'package:plop/settings.dart';
import 'package:plop/settings_panel.dart';

void main() {
  testWidgets('recording a shortcut shows it right away', (tester) async {
    debugDesktopOverride = true;
    addTearDown(() => debugDesktopOverride = null);
    final settings = Settings.inMemory();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSettings(context, settings),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(Hotkeys.snipLabel));
    await tester.pump();
    expect(find.text('…'), findsOneWidget);

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
}
