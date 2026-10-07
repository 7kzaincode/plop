// The Dock badge (macOS) and taskbar flash (Windows) for items that land
// while plop is in the background, with the window channel standing in for
// the runner and the lifecycle channel for the window.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plop/window.dart';
import 'package:plop_core/plop_core.dart';

void main() {
  const window = MethodChannel('plop/window');

  ShelfItem item(String id) => ShelfItem(
    id: id,
    originId: 'phone',
    originName: "Zain's iPhone",
    name: '$id.png',
    size: 1536,
    mime: 'image/png',
    kind: ItemKind.file,
    expiresAt: DateTime.now().add(const Duration(minutes: 2)),
    ttl: const Duration(minutes: 2),
  );

  Future<void> lifecycle(WidgetTester tester, AppLifecycleState state) =>
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.lifecycle.name,
        const StringCodec().encodeMessage(state.toString()),
        (_) {},
      );

  testWidgets('an item back from a peer that dropped off is not fresh', (
    tester,
  ) async {
    // Each signal that something new landed: a badge marked fresh on
    // macOS, a flash elsewhere; and the badge counts as they go.
    final fresh = <String>[];
    final counts = <int>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(window, (call) async {
      final args = call.arguments;
      if (call.method == 'flash') fresh.add('flash');
      if (call.method == 'badge' && args is Map) {
        counts.add(args['count'] as int);
        if (args['fresh'] == true) fresh.add('badge');
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(window, null);
      Arrivals.reset();
    });
    Arrivals.reset();

    // Seen on the focused shelf, then the window goes to the background and
    // the phone sleeps (its uncopied item leaves) and wakes (it is back).
    await lifecycle(tester, AppLifecycleState.resumed);
    Arrivals.update([item('a')]);
    await lifecycle(tester, AppLifecycleState.hidden);
    Arrivals.update([]);
    Arrivals.update([item('a')]);
    await tester.pump();
    expect(fresh, isEmpty);

    // Something new is still news.
    Arrivals.update([item('a'), item('b')]);
    await tester.pump();
    expect(fresh, [Platform.isMacOS ? 'badge' : 'flash']);
    if (Platform.isMacOS) expect(counts, [1]);
  });
}
