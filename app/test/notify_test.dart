// The gate and the coalescing behind lib/notify.dart, with the plugin's
// channel standing in for the OS and the lifecycle channel for the window.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plop/notify.dart';
import 'package:plop/settings.dart';
import 'package:plop_core/plop_core.dart';

void main() {
  const notifier = MethodChannel('local_notifier');
  const window = MethodChannel('plop/window');
  late List<Map<Object?, Object?>> shown; // arguments of every 'notify'
  late List<String> windowCalls;
  late Settings settings;

  /// Stands in for the OS: remembers what was shown and what the window
  /// was asked to do.
  Future<void> start(WidgetTester tester) async {
    Notify.reset();
    shown = [];
    windowCalls = [];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(notifier, (call) async {
      if (call.method == 'notify') shown.add((call.arguments as Map).cast());
      return true;
    });
    messenger.setMockMethodCallHandler(window, (call) async {
      windowCalls.add(call.method);
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(notifier, null);
      messenger.setMockMethodCallHandler(window, null);
      Notify.reset();
    });
    settings = Settings.inMemory();
    await Notify.init(settings);
  }

  /// What the engine sends when the window gains or loses focus.
  Future<void> lifecycle(WidgetTester tester, AppLifecycleState state) =>
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.lifecycle.name,
        const StringCodec().encodeMessage(state.toString()),
        (_) {},
      );

  ShelfItem item(
    String id, {
    String from = 'phone',
    String sender = "Zain's iPhone",
    String name = 'IMG_4821.png',
    int size = 1536,
    ItemKind kind = ItemKind.file,
  }) => ShelfItem(
    id: id,
    originId: from,
    originName: sender,
    name: name,
    size: size,
    mime: 'application/octet-stream',
    kind: kind,
    expiresAt: DateTime.now().add(const Duration(minutes: 2)),
    ttl: const Duration(minutes: 2),
  );

  testWidgets('nothing is said while the window is focused', (tester) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.resumed);
    expect(Notify.windowFocused, isTrue);
    Notify.arrived([item('a')]);
    Notify.say('plopped clipboard');
    await tester.pump(Notify.burst * 2);
    expect(shown, isEmpty);
  });

  testWidgets('an arrival names the sender, the item and its size', (
    tester,
  ) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.inactive);
    expect(Notify.windowFocused, isFalse);
    Notify.arrived([item('a'), item('t', kind: ItemKind.text, name: 'hi')]);
    expect(shown, isEmpty, reason: 'waits out the burst window');
    await tester.pump(Notify.burst);
    expect(shown, hasLength(2));
    expect(shown[0]['title'], "Zain's iPhone");
    expect(shown[0]['body'], 'IMG_4821.png · 1.5 KB');
    expect(shown[1]['body'], 'hi', reason: 'text has no size worth saying');
  });

  testWidgets('three within two seconds are one notification', (tester) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.hidden);
    Notify.arrived([item('a')]);
    await tester.pump(const Duration(milliseconds: 500));
    Notify.arrived([item('a'), item('b', name: 'IMG_4822.png')]);
    await tester.pump(const Duration(milliseconds: 500));
    Notify.arrived([
      item('a'),
      item('b', name: 'IMG_4822.png'),
      item('c', name: 'IMG_4823.png'),
    ]);
    await tester.pump(Notify.burst);
    expect(shown, hasLength(1));
    expect(shown.single['title'], "3 items from Zain's iPhone");
    expect(shown.single['body'], 'IMG_4821.png · IMG_4822.png · IMG_4823.png');
  });

  testWidgets('senders are kept apart', (tester) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.inactive);
    Notify.arrived([
      item('a'),
      item('b', from: 'mac', sender: 'Studio', name: 'notes.txt'),
    ]);
    await tester.pump(Notify.burst);
    expect([for (final s in shown) s['title']], ["Zain's iPhone", 'Studio']);
  });

  testWidgets('an item is announced once, not again when it expires', (
    tester,
  ) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.inactive);
    Notify.arrived([item('a')]);
    await tester.pump(Notify.burst);
    Notify.arrived([item('a')]);
    await tester.pump(Notify.burst);
    Notify.arrived([]); // expired
    await tester.pump(Notify.burst);
    expect(shown, hasLength(1));
  });

  testWidgets(
    'an item that drops off with its peer and comes back is not new',
    (tester) async {
      // The core drops a peer's uncopied items on a missed poll and brings
      // them back a moment later, as when a phone sleeps and wakes.
      await start(tester);
      await lifecycle(tester, AppLifecycleState.hidden);
      Notify.arrived([item('a')]);
      await tester.pump(Notify.burst);
      Notify.arrived([]);
      await tester.pump(const Duration(seconds: 5));
      Notify.arrived([item('a')]);
      await tester.pump(Notify.burst);
      expect(shown, hasLength(1));
    },
  );

  testWidgets('what has expired and left is forgotten, not before', (
    tester,
  ) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.hidden);
    final old = ShelfItem(
      id: 'old',
      originId: 'phone',
      originName: "Zain's iPhone",
      name: 'big.mov',
      size: 1 << 30,
      mime: 'video/quicktime',
      kind: ItemKind.file,
      // Past its expiry, still on the shelf while a transfer holds it.
      expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      ttl: const Duration(minutes: 2),
    );
    Notify.arrived([old, item('b')]);
    await tester.pump(Notify.burst);
    Notify.arrived([old, item('b')]);
    await tester.pump(Notify.burst);
    expect(shown, hasLength(2), reason: 'each once');
    expect(Notify.debugSeen, unorderedEquals([old.key, item('b').key]));

    Notify.arrived([item('b')]); // the transfer is done and it is gone
    expect(Notify.debugSeen, [item('b').key]);
  });

  testWidgets('what the first sync after launch brings is not announced', (
    tester,
  ) async {
    // A launch at login, window not focused: the other devices' shelves
    // fill in over the first seconds, and none of it is news.
    await start(tester);
    await lifecycle(tester, AppLifecycleState.hidden);
    final changes = StreamController<void>.broadcast();
    addTearDown(changes.close);
    var remote = [item('a')];
    Notify.watchItems(changes.stream, () => remote);
    await tester.pump(Notify.burst);
    remote = [item('a'), item('b', from: 'mac', sender: 'Studio')];
    changes.add(null);
    await tester.pump(Notify.burst);
    expect(shown, isEmpty);

    await tester.pump(Notify.grace);
    remote = [...remote, item('c', name: 'IMG_4823.png')];
    changes.add(null);
    await tester.pump(Notify.burst);
    expect(shown, hasLength(1));
    expect(shown.single['body'], 'IMG_4823.png · 1.5 KB');
  });

  testWidgets('focusing the window before the burst ends cancels it', (
    tester,
  ) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.inactive);
    Notify.arrived([item('a')]);
    await tester.pump(const Duration(seconds: 1));
    await lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump(Notify.burst);
    expect(shown, isEmpty);
  });

  testWidgets('the setting switches everything off', (tester) async {
    await start(tester);
    settings.notifications = false;
    await lifecycle(tester, AppLifecycleState.inactive);
    Notify.arrived([item('a')]);
    Notify.say('plopped clipboard');
    await tester.pump(Notify.burst);
    expect(shown, isEmpty);
  });

  testWidgets('closing into the tray is explained once, ever', (tester) async {
    await start(tester);
    // Still focused: the close is happening in front of the user.
    await lifecycle(tester, AppLifecycleState.resumed);
    Notify.hiddenToTray();
    await tester.pump();
    expect(shown, hasLength(1));
    expect(shown.single['title'], 'plop is still running in the tray');
    expect(settings.trayNoticeShown, isTrue);

    Notify.hiddenToTray();
    await tester.pump();
    expect(shown, hasLength(1));

    // Next launch: remembered.
    Notify.reset();
    await Notify.init(settings);
    Notify.hiddenToTray();
    await tester.pump();
    expect(shown, hasLength(1));
  });

  testWidgets('with notifications off the tray notice waits', (tester) async {
    await start(tester);
    settings.notifications = false;
    Notify.hiddenToTray();
    await tester.pump();
    expect(shown, isEmpty);
    expect(settings.trayNoticeShown, isFalse);
  });

  testWidgets("a shortcut's result is said; a click shows the window", (
    tester,
  ) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.inactive);
    Notify.say('plopped clipboard');
    await tester.pump();
    expect(shown, hasLength(1));
    expect(shown.single['title'], 'plop');
    expect(shown.single['body'], 'plopped clipboard');

    // The OS reports the click back over the plugin's channel.
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      notifier.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onLocalNotificationClick', {
          'notificationId': shown.single['identifier'],
        }),
      ),
      (_) {},
    );
    await tester.pump();
    expect(windowCalls, contains('show'));
  });

  testWidgets('a click that comes as the "default" action shows it too', (
    tester,
  ) async {
    // Linux: libnotify reports a click on the body as the action keyed
    // "default", which is how the plugin passes it on.
    await start(tester);
    await lifecycle(tester, AppLifecycleState.hidden);
    Notify.say('plopped clipboard');
    await tester.pump();
    final actions = shown.single['actions'] as List;
    expect(actions, Platform.isLinux ? hasLength(1) : isEmpty);

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      notifier.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('onLocalNotificationClickAction', {
          'notificationId': shown.single['identifier'],
          'actionIndex': 0,
        }),
      ),
      (_) {},
    );
    await tester.pump();
    expect(windowCalls, contains('show'));
  });
}
