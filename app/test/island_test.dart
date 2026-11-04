// What lib/island.dart sends the island (Island.swift on macOS, island.cpp
// on Windows, island.cc on Linux), that it shows on Windows and Linux only
// where the runner says it can, and that lib/notify.dart hands it arrivals
// and shortcut results in place of notifications, under the same rules.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plop/island.dart';
import 'package:plop/notify.dart';
import 'package:plop/settings.dart';
import 'package:plop_core/plop_core.dart';

void main() {
  const island = MethodChannel('plop/island');
  const notifier = MethodChannel('local_notifier');
  late List<MethodCall> calls;
  late List<Object?> notified;

  /// The island's runner and the notification plugin, stood in for; with
  /// [activate], the island as if set up. [available] is what the runner
  /// answers when asked whether it can show the island; an [Exception]
  /// is thrown instead, as by a runner without the channel.
  Future<void> start(
    WidgetTester tester, {
    bool activate = true,
    Object? available,
  }) async {
    Notify.reset();
    Island.reset();
    calls = [];
    notified = [];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(island, (call) async {
      calls.add(call);
      if (call.method != 'available') return null;
      if (available is Exception) throw available;
      return available;
    });
    messenger.setMockMethodCallHandler(notifier, (call) async {
      if (call.method == 'notify') notified.add(call.arguments);
      return true;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(island, null);
      messenger.setMockMethodCallHandler(notifier, null);
      Notify.reset();
      Island.reset();
    });
    await Notify.init(Settings.inMemory());
    if (activate) Island.debugActivate();
  }

  /// [Island.init] as it runs on [os], with a real node to watch. The node
  /// is stopped once init is done: the island only reads the items it is
  /// handed.
  Future<void> initAs(WidgetTester tester, String os) async {
    Island.debugOs = os;
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('plop_island');
      final node = await PlopNode.start(
        dir: Directory('${root.path}/store'),
        discovery: StaticDiscovery(),
        name: 'me',
      );
      try {
        await Island.init(node);
      } finally {
        await node.stop();
        await root.delete(recursive: true);
      }
    });
  }

  Future<void> lifecycle(WidgetTester tester, AppLifecycleState state) =>
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.lifecycle.name,
        const StringCodec().encodeMessage(state.toString()),
        (_) {},
      );

  ShelfItem item(
    String id, {
    String name = 'IMG_4821.png',
    String mime = 'image/png',
    int size = 1536,
    ItemKind kind = ItemKind.file,
  }) => ShelfItem(
    id: id,
    originId: 'phone',
    originName: "Zain's iPhone",
    name: name,
    size: size,
    mime: mime,
    kind: kind,
    expiresAt: DateTime.now().add(const Duration(minutes: 2)),
    ttl: const Duration(minutes: 2),
  );

  /// Lets the island's real async work (drawing its tiles) finish.
  Future<void> settle(WidgetTester tester) async {
    // Each await on the engine (the picture, then its PNG) needs real time,
    // then a pump to come back into the test's zone.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
  }

  testWidgets('arrivals go to the island, not to notifications', (
    tester,
  ) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.inactive);
    Notify.arrived([item('a'), item('b', name: 'notes.pdf', mime: 'x')]);
    await tester.pump(Island.burst);
    await settle(tester);
    final show = calls.singleWhere((c) => c.method == 'show');
    final args = (show.arguments as Map).cast<String, Object?>();
    expect(args['sender'], "Zain's iPhone");
    final items = (args['items'] as List).cast<Map<Object?, Object?>>();
    expect(items.map((i) => i['title']), ['IMG_4821.png', 'notes.pdf']);
    expect(notified, isEmpty, reason: 'one calm thing, not two');
  });

  testWidgets('a shortcut says its result on the island, red when it failed', (
    tester,
  ) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.hidden);
    Notify.say('plopped clipboard');
    Notify.say('nothing to paste', ok: false);
    final says = calls.where((c) => c.method == 'say').toList();
    expect(says.map((c) => (c.arguments as Map)['text']), [
      'plopped clipboard',
      'nothing to paste',
    ]);
    expect(says.map((c) => (c.arguments as Map)['ok']), [true, false]);
    expect(notified, isEmpty);
  });

  testWidgets('arrivals show while the window is focused; says do not', (
    tester,
  ) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.resumed);
    Notify.arrived([item('a')]);
    Notify.say('plopped clipboard');
    await tester.pump(Notify.burst);
    await settle(tester);
    expect(calls.map((c) => c.method), ['show']);
  });

  testWidgets('a row: its title, line, buttons, and what drags out', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('plop_island');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/text.txt')
      ..writeAsStringSync('meeting moved to 4pm');
    final text = item(
      't',
      name: 'meeting moved to 4pm',
      kind: ItemKind.text,
      size: file.lengthSync(),
    )..path = file.path;
    final picture = item('p')..path = '${dir.path}/IMG_4821.png';
    File(picture.path!).writeAsBytesSync([1, 2, 3]);
    final pdf = item('d', name: 'lease.pdf', mime: 'application/pdf');
    final folder = item('f', name: 'photos', kind: ItemKind.folder);

    final rows = (await tester.runAsync(
      () => Future.wait([text, picture, pdf, folder].map(Island.describe)),
    ))!;
    final (t, p, d, f) = (rows[0], rows[1], rows[2], rows[3]);
    // Text: only its length until hovered; the words drag out.
    expect(t['title'], 'text');
    expect(t['reveal'], 'meeting moved to 4pm');
    expect(t['meta'], '20 characters');
    expect(t['dragText'], 'meeting moved to 4pm');
    expect(t['actions'], ['copy']);
    // A picture here: its thumbnail, and the file drags out.
    expect(p['thumb'], picture.path);
    expect(p['dragFile'], picture.path);
    expect(p['actions'], ['copy', 'save']);
    // Not copied yet: nothing to drag, nothing to show but the tile.
    expect(d.containsKey('dragFile'), isFalse);
    expect(d['icon'], isA<Uint8List>());
    expect(d['actions'], [
      'copy',
      'save',
    ], reason: 'the same order down a list');
    expect(f['meta'], 'folder · 1.5 KB');
    expect(f['actions'], ['save']);
  });

  testWidgets('a copy that beats the island still shows on its row', (
    tester,
  ) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.inactive);
    final text = item('t', name: 'otp 123456', kind: ItemKind.text);
    // Auto-copy finished first; the arrival is still gathering.
    Island.copied(text);
    final row = (await tester.runAsync(() => Island.describe(text)))!;
    expect(row['mark'], '✓ copied automatically');
    // Shown in time, so no line of its own.
    Notify.arrived([text]);
    await tester.pump(Island.burst);
    await settle(tester);
    await tester.pump(Island.burst * 2);
    expect(calls.where((c) => c.method == 'say'), isEmpty);
    final show = calls.singleWhere((c) => c.method == 'show');
    final rows = ((show.arguments as Map)['items'] as List).cast<Map>();
    expect(rows.single['mark'], '✓ copied automatically');
  });

  testWidgets('with arrivals switched off, auto-copy says nothing either', (
    tester,
  ) async {
    await start(tester);
    final settings = Settings.inMemory()..notifications = false;
    await Notify.init(settings);
    await lifecycle(tester, AppLifecycleState.inactive);
    Island.copied(item('t', name: 'otp 123456', kind: ItemKind.text));
    await tester.pump(Island.burst * 2);
    expect(calls, isEmpty);
  });

  testWidgets('a copy whose arrival never shows says so on its own', (
    tester,
  ) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.inactive);
    Island.copied(item('t', name: 'otp 123456', kind: ItemKind.text));
    await tester.pump(Island.burst * 2);
    final say = calls.singleWhere((c) => c.method == 'say');
    expect((say.arguments as Map)['text'], "copied text from Zain's iPhone");
  });

  testWidgets('a send overtaken by a newer one is dropped', (tester) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.inactive);
    // Both start describing their items; the phone's would land last.
    Island.arrived('Phone', [
      item('t', name: 'a', kind: ItemKind.text),
    ]).ignore();
    Island.arrived('iPad', [item('p')]).ignore();
    await settle(tester);
    final shows = calls.where((c) => c.method == 'show').toList();
    expect(shows, hasLength(1));
    final args = (shows.single.arguments as Map).cast<String, Object?>();
    expect(args['sender'], 'iPad');
    expect(args['count'], 1);
  });

  testWidgets('a result for a row no longer showing says it on its own', (
    tester,
  ) async {
    await start(tester);
    // The native side answers that the row was not there to mark.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(island, (
      call,
    ) async {
      calls.add(call);
      return call.method == 'mark' ? false : null;
    });
    await Island.debugMark('k', '✓ saved to Downloads · click to show');
    final say = calls.singleWhere((c) => c.method == 'say');
    expect((say.arguments as Map)['text'], 'saved to Downloads');
    // Progress is not worth an island of its own.
    calls.clear();
    await Island.debugMark('k', 'copying…', settled: false);
    expect(calls.where((c) => c.method == 'say'), isEmpty);
  });

  testWidgets('a phone uploading through the web shelf shows as an arrival', (
    tester,
  ) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.inactive);
    final changes = StreamController<void>.broadcast();
    addTearDown(changes.close);
    // This Mac's own item, but a phone put it up through the web page.
    final upload = ShelfItem(
      id: 'u',
      originId: 'mac',
      originName: 'Zain’s MacBook',
      name: 'IMG_0042.heic',
      size: 2048,
      mime: 'image/heic',
      kind: ItemKind.file,
      expiresAt: DateTime.now().add(const Duration(minutes: 2)),
      ttl: const Duration(minutes: 2),
    );
    var items = <ShelfItem>[];
    Notify.watchItems(
      changes.stream,
      () => items,
      () => const [],
      isUpload: (key) => key == upload.key,
    );
    // Right after launch: an upload has no quiet period to wait out.
    items = [upload];
    changes.add(null);
    await tester.pump(Island.burst);
    await settle(tester);
    final show = calls.singleWhere((c) => c.method == 'show');
    expect((show.arguments as Map)['sender'], 'a phone (web)');
    Notify.reset(); // its settling-in timer
  });

  // The pill above the taskbar: Windows always, Linux under X11.
  for (final os in ['windows', 'linux']) {
    testWidgets('on $os, arrivals go to the pill once the runner can show it', (
      tester,
    ) async {
      await start(tester, activate: false, available: true);
      await initAs(tester, os);
      expect(calls.map((c) => c.method), ['available']);
      expect(Island.supported, isTrue);
      expect(Island.active, isTrue);

      await lifecycle(tester, AppLifecycleState.inactive);
      Notify.arrived([item('a')]);
      Notify.say('plopped clipboard');
      await tester.pump(Island.burst);
      await settle(tester);
      expect(calls.where((c) => c.method == 'show'), hasLength(1));
      expect(calls.where((c) => c.method == 'say'), hasLength(1));
      expect(notified, isEmpty, reason: 'the pill instead of notifications');
    });
  }

  testWidgets('Wayland keeps notifications: its runner says no', (
    tester,
  ) async {
    await start(tester, activate: false, available: false);
    await initAs(tester, 'linux');
    expect(Island.supported, isFalse);
    expect(Island.active, isFalse);

    await lifecycle(tester, AppLifecycleState.inactive);
    Notify.arrived([item('a')]);
    await tester.pump(Notify.burst);
    await settle(tester);
    expect(calls.map((c) => c.method), ['available'], reason: 'nothing shown');
    expect(notified, hasLength(1));
  });

  testWidgets('a runner without the pill keeps notifications too', (
    tester,
  ) async {
    await start(tester, activate: false, available: MissingPluginException());
    await initAs(tester, 'windows');
    expect(Island.active, isFalse);

    await lifecycle(tester, AppLifecycleState.hidden);
    Notify.say('plopped clipboard');
    await tester.pump();
    expect(calls.where((c) => c.method == 'say'), isEmpty);
    expect(notified, hasLength(1));
  });

  testWidgets('macOS always has the island; phones never ask', (tester) async {
    await start(tester, activate: false, available: false);
    await initAs(tester, 'macos');
    expect(Island.active, isTrue, reason: 'no need to ask the runner');
    Island.reset();
    await initAs(tester, 'android');
    expect(Island.active, isFalse);
    expect(calls, isEmpty);
  });
}
