// What lib/island.dart sends the macOS island (Island.swift), and that
// lib/notify.dart hands it arrivals and shortcut results in place of
// notifications, under the same rules.
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

  Future<void> start(WidgetTester tester) async {
    Notify.reset();
    Island.reset();
    calls = [];
    notified = [];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(island, (call) async {
      calls.add(call);
      return null;
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
    Island.debugActivate();
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

  testWidgets('nothing shows while the window is focused', (tester) async {
    await start(tester);
    await lifecycle(tester, AppLifecycleState.resumed);
    Notify.arrived([item('a')]);
    Notify.say('plopped clipboard');
    await tester.pump(Notify.burst);
    await settle(tester);
    expect(calls, isEmpty);
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
}
