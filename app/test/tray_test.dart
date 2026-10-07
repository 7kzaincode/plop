// The close button on Windows and Linux reaches Dart as Flutter's request
// to exit; lib/tray.dart turns it into a hide while the icon is up.
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plop/tray.dart';

void main() {
  const window = MethodChannel('plop/window');

  testWidgets('a close with the icon up hides the window, not plop', (
    tester,
  ) async {
    final calls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(window, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(window, null);
      Tray.debugActive = null;
    });

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
    }
  });
}
