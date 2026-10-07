// The close button on Windows and Linux reaches Dart as Flutter's request
// to exit; lib/tray.dart turns it into a hide while the icon is up, the
// first time with a notification saying so.
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plop/notify.dart';
import 'package:plop/settings.dart';
import 'package:plop/tray.dart';

void main() {
  const window = MethodChannel('plop/window');
  const notifier = MethodChannel('local_notifier');

  testWidgets('a close with the icon up hides the window, not plop', (
    tester,
  ) async {
    final calls = <String>[];
    final notified = <Object?>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(window, (call) async {
      calls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(notifier, (call) async {
      if (call.method == 'notify') notified.add(call.arguments);
      return true;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(window, null);
      messenger.setMockMethodCallHandler(notifier, null);
      Tray.debugActive = null;
      Notify.reset();
    });
    Notify.reset();
    await Notify.init(Settings.inMemory());

    // No icon: closing quits, as it always did.
    Tray.debugActive = false;
    expect(await Tray.onExitRequested(), AppExitResponse.exit);
    expect(calls, isEmpty);

    Tray.debugActive = true;
    final answer = await Tray.onExitRequested();
    await tester.pump();
    if (Platform.isMacOS) {
      // Closing the window never asks on macOS; this is ⌘Q.
      expect(answer, AppExitResponse.exit);
      expect(calls, isEmpty);
    } else {
      expect(answer, AppExitResponse.cancel);
      expect(calls, ['hide']);
      // The first time, a notification says where plop went.
      expect(notified, hasLength(1));
      await Tray.onExitRequested();
      await tester.pump();
      expect(notified, hasLength(1));
    }
  });

  test('Linux waits a while for the panel to host the icon', () async {
    var calls = 0;
    final late = await Tray.waitForHost(
      () async => ++calls == 3,
      every: Duration.zero,
      tries: 5,
    );
    expect(late, isTrue, reason: 'the panel came up after plop');
    expect(calls, 3);

    calls = 0;
    final never = await Tray.waitForHost(
      () async {
        calls++;
        return false;
      },
      every: Duration.zero,
      tries: 5,
    );
    expect(never, isFalse, reason: 'no tray on this desktop');
    expect(calls, 5);
  });
}
