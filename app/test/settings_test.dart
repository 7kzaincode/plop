import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:plop/hotkeys.dart';
import 'package:plop/settings.dart';

void main() {
  // The panel's "couldn't save that" note depends on this: a write that
  // fails must fail the returned future rather than vanish.
  test('a failed write fails setHotkey', () async {
    final dir = Directory.systemTemp.createTempSync('plop_settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final blocker = File('${dir.path}/blocker')..writeAsStringSync('');
    final settings = Settings.at(File('${blocker.path}/settings.json'));
    await expectLater(
      settings.setHotkey('snip', Hotkeys.defaultSnip),
      throwsA(isA<FileSystemException>()),
    );
    // The binding itself is kept, so it works until plop quits.
    expect(settings.hotkey('snip'), isNotNull);
  });

  // A saved port that is not one would make binding throw ArgumentError,
  // which no fallback catches; it reads as nothing saved instead.
  test('webPort reads back only a port', () {
    final settings = Settings.inMemory();
    expect(settings.webPort, isNull);
    for (final bad in [0, -1, 65536, 70000, 1 << 40]) {
      settings.webPort = bad;
      expect(settings.webPort, isNull, reason: '$bad');
    }
    for (final good in [1, 7567, 65535]) {
      settings.webPort = good;
      expect(settings.webPort, good);
    }
  });

  test('a write that works reads back', () async {
    final dir = Directory.systemTemp.createTempSync('plop_settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/deeper/settings.json');
    await Settings.at(file).setHotkey('clip', Hotkeys.defaultClip);
    expect(file.existsSync(), isTrue);
  });

  // main.dart reads 'grab' at launch beside 'snip' and 'clip'; each name
  // keeps its own binding, and a reset one reads back as none (the default).
  test('the grab shortcut is saved under its own name', () async {
    final dir = Directory.systemTemp.createTempSync('plop_settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/settings.json');
    final own = HotKey(
      key: PhysicalKeyboardKey.keyY,
      modifiers: [HotKeyModifier.control, HotKeyModifier.meta],
    );
    final settings = await Settings.loadFrom(file);
    expect(settings.hotkey('grab'), isNull, reason: 'nothing saved yet');
    await settings.setHotkey('clip', Hotkeys.defaultClip);
    await settings.setHotkey('grab', own);

    final reread = await Settings.loadFrom(file);
    expect(Hotkeys.same(reread.hotkey('grab')!, own), isTrue);
    expect(Hotkeys.same(reread.hotkey('clip')!, Hotkeys.defaultClip), isTrue);
    expect(reread.hotkey('snip'), isNull);

    await reread.setHotkey('grab', null);
    expect((await Settings.loadFrom(file)).hotkey('grab'), isNull);
  });

  // Anyone nearby could fill the clipboard, so it starts off, and only an
  // explicit true turns it on: a file edited by hand stays off.
  test('copying arrivals is off until switched on, and remembered', () async {
    final dir = Directory.systemTemp.createTempSync('plop_settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/settings.json');
    final settings = await Settings.loadFrom(file);
    expect(settings.autoCopy, isFalse);

    /// What a relaunch reads, once the setter's background write has landed.
    Future<bool> relaunched(bool expected) async {
      final end = DateTime.now().add(const Duration(seconds: 2));
      while (DateTime.now().isBefore(end)) {
        final now = (await Settings.loadFrom(file)).autoCopy;
        if (now == expected) return now;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      return !expected;
    }

    settings.autoCopy = true;
    expect(await relaunched(true), isTrue);
    settings.autoCopy = false;
    expect(await relaunched(false), isFalse);

    file.writeAsStringSync('{"autoCopy": "yes"}');
    expect((await Settings.loadFrom(file)).autoCopy, isFalse);
  });
}
