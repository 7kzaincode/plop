// Drives the shelf with a real pair of nodes on loopback, like layout_test.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plop/grab.dart';
import 'package:plop/main.dart';
import 'package:plop/settings.dart';
import 'package:plop_core/plop_core.dart';

void main() {
  late Directory root;
  late PlopNode me, other;

  /// Starts [me] seeing [other], which has one text item [me] has mirrored.
  Future<void> startNodes(WidgetTester tester) => tester.runAsync(
    // flutter_test stubs HttpClient to answer 400; the nodes need the real one.
    () => HttpOverrides.runWithHttpOverrides(() async {
      root = await Directory.systemTemp.createTemp('plop_shelf');
      outDir = Directory('${root.path}/out')..createSync();
      final dMe = StaticDiscovery();
      me = await PlopNode.start(
        dir: Directory('${root.path}/me'),
        discovery: dMe,
        name: 'me',
      );
      other = await PlopNode.start(
        dir: Directory('${root.path}/other'),
        discovery: StaticDiscovery(),
        name: 'other',
      );
      dMe.add(
        Peer(
          id: other.id,
          name: 'other',
          hosts: ['127.0.0.1'],
          port: other.port,
        ),
      );
      await other.addText('hello');
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (!me.items.any((i) => i.isReady && i.originId == other.id)) {
        if (DateTime.now().isAfter(end)) throw 'item did not sync';
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }, _RealHttp()),
  );

  Future<void> stopNodes(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await other.stop();
      await me.stop();
      await root.delete(recursive: true);
    });
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(PlopApp(node: me, settings: Settings.inMemory()));
    await tester.pump(); // autofocus
  }

  Future<void> pressEnter(WidgetTester tester, {int repeats = 0}) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    for (var i = 0; i < repeats; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
  }

  testWidgets('Enter grabs the newest item once per press', (tester) async {
    debugDesktopOverride = true;
    addTearDown(() => debugDesktopOverride = null);
    await startNodes(tester);

    // Count copies, and hold one open to stand in for a long download.
    var copies = 0;
    Completer<void>? gate;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copies++;
        await gate?.future;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await pumpApp(tester);

    // Holding the key repeats it; repeats are not presses.
    await tester.runAsync(() async {
      await pressEnter(tester, repeats: 2);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(copies, 1);

    // A press while the first grab is still running is dropped, not queued.
    gate = Completer<void>();
    await tester.runAsync(() async {
      await pressEnter(tester);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await pressEnter(tester);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      gate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    expect(copies, 2);

    await stopNodes(tester);
  });

  testWidgets('a long file name keeps its tail when it truncates', (
    tester,
  ) async {
    debugDesktopOverride = false;
    addTearDown(() => debugDesktopOverride = null);
    await startNodes(tester);
    // Two snips seconds apart differ only in the seconds, which an end
    // ellipsis would drop first.
    const name = 'Screenshot 2026-10-06 at 14.23.11.png';
    await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        await other.addBytes(List.filled(1024, 1), name);
        final end = DateTime.now().add(const Duration(seconds: 5));
        while (!me.items.any((i) => i.name == name)) {
          if (DateTime.now().isAfter(end)) throw 'item did not sync';
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }, _RealHttp()),
    );
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpApp(tester);
    expect(tester.takeException(), isNull);

    expect(find.text(name), findsNothing, reason: 'split into head and tail');
    expect(find.text('14.23.11.png'), findsOneWidget);
    // Text items are labelled by their first line and keep the end ellipsis.
    expect(find.text('hello'), findsOneWidget);

    await stopNodes(tester);
  });
}

class _RealHttp extends HttpOverrides {}
