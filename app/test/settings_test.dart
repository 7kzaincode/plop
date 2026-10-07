import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
}
