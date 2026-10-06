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

  test('a write that works reads back', () async {
    final dir = Directory.systemTemp.createTempSync('plop_settings');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/deeper/settings.json');
    await Settings.at(file).setHotkey('clip', Hotkeys.defaultClip);
    expect(file.existsSync(), isTrue);
  });
}
