// Drives the shelf with a real pair of nodes on loopback, like layout_test.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plop/grab.dart';
import 'package:plop/main.dart';
import 'package:plop/settings.dart';
import 'package:plop/shelf_screen.dart';
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

  Future<void> pumpApp(
    WidgetTester tester, {
    GlobalKey<ShelfScreenState>? screenKey,
  }) async {
    await tester.pumpWidget(
      PlopApp(node: me, settings: Settings.inMemory(), screenKey: screenKey),
    );
    await tester.pump(); // autofocus
    // Rows fade in from nothing, and a row that is not painted cannot
    // report an overflow; let them arrive before a test looks at them.
    await tester.pump(const Duration(milliseconds: 250));
  }

  /// Puts a 1 KB file called [name] on [other] and waits for [me] to see it.
  Future<void> addFile(WidgetTester tester, String name) => tester.runAsync(
    () => HttpOverrides.runWithHttpOverrides(() async {
      await other.addBytes(List.filled(1024, 1), name);
      final end = DateTime.now().add(const Duration(seconds: 5));
      while (!me.items.any((i) => i.name == name)) {
        if (DateTime.now().isAfter(end)) throw 'item did not sync';
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }, _RealHttp()),
  );

  /// The head and tail a middle-truncated [name] is drawn as, checked to add
  /// back up to the name and to part on a character boundary.
  (String, String) splitName(WidgetTester tester, String name) {
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .where((t) => t.isNotEmpty && t != name);
    final head = texts.singleWhere(name.startsWith);
    final tail = texts.singleWhere(name.endsWith);
    expect(head + tail, name);
    expect(
      tail,
      name.characters.takeLast(tail.characters.length).toString(),
      reason: 'the tail starts on a whole character',
    );
    return (head, tail);
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

  testWidgets('Tab and the arrows pick a row; Enter grabs it, Esc lets go', (
    tester,
  ) async {
    debugDesktopOverride = true;
    addTearDown(() => debugDesktopOverride = null);
    await startNodes(tester);
    // A second, newer item, so "the focused row" and "the newest" differ.
    await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        await other.addText('world');
        final end = DateTime.now().add(const Duration(seconds: 5));
        while (!me.items.any((i) => i.isReady && i.name == 'world')) {
          if (DateTime.now().isAfter(end)) throw 'item did not sync';
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }, _RealHttp()),
    );
    final copied = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await pumpApp(tester);

    // Tab reaches the TTL chip, ↓ the first row, ↓ the older one below it.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    final ring = find.byWidgetPredicate(
      (w) => w is Container && w.foregroundDecoration != null,
    );
    expect(ring, findsOneWidget, reason: 'one row shows the focus ring');
    expect(find.descendant(of: ring, matching: find.text('hello')), findsOne);

    await tester.runAsync(() async {
      await pressEnter(tester);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(copied, ['hello']);

    // Esc returns to the shelf, where Enter grabs the newest again.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(ring, findsNothing);
    await tester.runAsync(() async {
      await pressEnter(tester);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(copied, ['hello', 'world']);

    await stopNodes(tester);
  });

  testWidgets('Enter on the focused TTL chip opens its menu, grabs nothing', (
    tester,
  ) async {
    debugDesktopOverride = true;
    addTearDown(() => debugDesktopOverride = null);
    await startNodes(tester);
    var copies = 0;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copies++;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await pumpApp(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.runAsync(() async {
      await pressEnter(tester);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<Duration>), findsWidgets);
    expect(copies, 0, reason: 'the chip took Enter, not the shelf');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuItem<Duration>), findsNothing);
    await stopNodes(tester);
  });

  testWidgets('Tab reaches the icon buttons; Enter presses them', (
    tester,
  ) async {
    debugDesktopOverride = true;
    addTearDown(() => debugDesktopOverride = null);
    await startNodes(tester);
    final copied = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await pumpApp(tester);

    // Chip, ↓ to the row, Tab onto the row's own copy icon: Enter there is
    // the icon's press, and the row above it does not grab a second time.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(); // a desktop row shows its icons once it is lit
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final ring = find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).border != null,
    );
    expect(
      find.descendant(of: ring, matching: find.byIcon(Icons.copy_rounded)),
      findsOneWidget,
      reason: 'the copy icon shows the ring',
    );
    await tester.runAsync(() async {
      await pressEnter(tester);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(copied, ['hello']);

    // Esc back to the shelf; chip, add, settings. Enter opens the panel.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    }
    await tester.pump();
    expect(
      find.descendant(of: ring, matching: find.byIcon(Icons.tune_rounded)),
      findsOneWidget,
      reason: 'the settings icon shows the ring',
    );
    await tester.runAsync(() async {
      await pressEnter(tester);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(copied, ['hello'], reason: 'the shelf did not grab');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);

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
    await addFile(tester, name);
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpApp(tester);
    expect(tester.takeException(), isNull);

    expect(find.text(name), findsNothing, reason: 'split into head and tail');
    final (head, tail) = splitName(tester, name);
    expect(tail, endsWith('.png'));
    expect(
      tester.renderObject<RenderParagraph>(find.text(head)).didExceedMaxLines,
      isTrue,
      reason: 'the head is the part that gives way',
    );
    // Text items are labelled by their first line and keep the end ellipsis.
    expect(find.text('hello'), findsOneWidget);

    await stopNodes(tester);
  });

  testWidgets('a wide CJK name fits a 320px row', (tester) async {
    debugDesktopOverride = false;
    addTearDown(() => debugDesktopOverride = null);
    await startNodes(tester);
    // Forty full-em characters: a fixed twelve-character tail alone is
    // wider than the space the name gets beside two action icons.
    final name = '${'渋谷区神宮前設計資料' * 4}.png';
    await addFile(tester, name);
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpApp(tester);
    expect(tester.takeException(), isNull);

    final (head, tail) = splitName(tester, name);
    expect(tail, endsWith('.png'));
    expect(
      tester.renderObject<RenderParagraph>(find.text(head)).didExceedMaxLines,
      isTrue,
    );

    await stopNodes(tester);
  });

  testWidgets('a toast stays up long enough to read, six seconds at most', (
    tester,
  ) async {
    debugDesktopOverride = true;
    addTearDown(() => debugDesktopOverride = null);
    await startNodes(tester);
    final screen = GlobalKey<ShelfScreenState>();
    await pumpApp(tester, screenKey: screen);

    // The pill keeps its text while it fades, so visibility is its opacity.
    bool shown(String msg) =>
        tester
            .widget<AnimatedOpacity>(
              find.ancestor(
                of: find.text(msg),
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .opacity >
        0;

    // 1.8 s, plus 40 ms for every character past the first twenty.
    Future<void> upFor(String msg, Duration d) async {
      screen.currentState!.toast(msg);
      await tester.pump();
      expect(shown(msg), isTrue);
      await tester.pump(d - const Duration(milliseconds: 100));
      expect(shown(msg), isTrue, reason: '${msg.length} chars, before $d');
      await tester.pump(const Duration(milliseconds: 200));
      expect(shown(msg), isFalse, reason: '${msg.length} chars, after $d');
    }

    await upFor('x' * 20, const Duration(milliseconds: 1800));
    await upFor('y' * 100, const Duration(seconds: 5));
    await upFor('z' * 200, const Duration(seconds: 6));

    await stopNodes(tester);
  });

  testWidgets('a long toast gives up its message, never its action word', (
    tester,
  ) async {
    debugDesktopOverride = false;
    addTearDown(() => debugDesktopOverride = null);
    await startNodes(tester);
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final screen = GlobalKey<ShelfScreenState>();
    await pumpApp(tester, screenKey: screen);

    // The everyday case stays on one inline span: the whole message, tail
    // of the file name included, plus the action in two lines.
    const usual = 'saved to Downloads/Quarterly report FINAL final v3.pdf';
    screen.currentState!.toast(usual, action: 'show', onTap: () {});
    await tester.pump();
    final inline = find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText().startsWith(usual),
    );
    expect(inline, findsOneWidget);
    expect(
      tester.renderObject<RenderParagraph>(inline).didExceedMaxLines,
      isFalse,
      reason: 'the file name must not lose its tail to the action word',
    );

    // Far too long: the message gives way, the action never does.
    final msg = 'saved to Downloads/${'a' * 80}.pdf';
    screen.currentState!.toast(msg, action: 'show', onTap: () {});
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      tester.renderObject<RenderParagraph>(find.text(msg)).didExceedMaxLines,
      isTrue,
      reason: 'the message is the part that gives way',
    );
    final action = find.text('·  show');
    expect(action, findsOneWidget);
    expect(
      tester.renderObject<RenderParagraph>(action).didExceedMaxLines,
      isFalse,
    );
    expect(tester.getRect(action).right, lessThanOrEqualTo(320 - 16));

    await stopNodes(tester);
  });

  testWidgets('a name with emoji splits between characters, never inside', (
    tester,
  ) async {
    debugDesktopOverride = true;
    addTearDown(() => debugDesktopOverride = null);
    await startNodes(tester);
    // Each camera is two UTF-16 units; counting twelve units back from the
    // end lands inside the fourth one, where a code-unit split would cut.
    const name =
        'a very long screenshot name from a camera roll export '
        '2026-10-06 📸📸📸📸📸.jpeg';
    await addFile(tester, name);
    await pumpApp(tester);
    expect(tester.takeException(), isNull);

    expect(find.text(name), findsNothing, reason: 'too wide even at 800px');
    final (_, tail) = splitName(tester, name);
    expect(tail, endsWith('📸.jpeg'));

    await stopNodes(tester);
  });
}

class _RealHttp extends HttpOverrides {}
