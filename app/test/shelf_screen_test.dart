// Drives the shelf with a real pair of nodes on loopback, like layout_test.
import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
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
  late StaticDiscovery dMe, dOther;

  /// Starts [me] seeing [other], which has one text item [me] has mirrored.
  /// [other] does not see [me] back until a test adds it to [dOther]. With
  /// [connect] false neither knows of the other, and [me] is alone. [poll]
  /// is how often each node polls its peers.
  Future<void> startNodes(
    WidgetTester tester, {
    bool connect = true,
    Duration poll = const Duration(seconds: 3),
  }) => tester.runAsync(
    // flutter_test stubs HttpClient to answer 400; the nodes need the real one.
    () => HttpOverrides.runWithHttpOverrides(() async {
      root = await Directory.systemTemp.createTemp('plop_shelf');
      outDir = Directory('${root.path}/out')..createSync();
      dMe = StaticDiscovery();
      dOther = StaticDiscovery();
      me = await PlopNode.start(
        dir: Directory('${root.path}/me'),
        discovery: dMe,
        name: 'me',
        pollInterval: poll,
      );
      other = await PlopNode.start(
        dir: Directory('${root.path}/other'),
        discovery: dOther,
        name: 'other',
        pollInterval: poll,
      );
      if (!connect) return;
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
    Settings? settings,
  }) async {
    await tester.pumpWidget(
      PlopApp(
        node: me,
        settings: settings ?? Settings.inMemory(),
        screenKey: screenKey,
      ),
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

  /// What the tooltip on the bar's count of devices says, by its [label].
  String barTip(WidgetTester tester, String label) => tester
      .widget<Tooltip>(
        find.ancestor(of: find.text(label), matching: find.byType(Tooltip)),
      )
      .message!;

  /// Search's over at once, so a test sees what the shelf says once nobody
  /// has turned up.
  void noGrace() {
    peerGrace = Duration.zero;
    addTearDown(() => peerGrace = const Duration(seconds: 6));
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

  testWidgets('a failure said while plop was away fades once the user looks', (
    tester,
  ) async {
    debugDesktopOverride = true;
    addTearDown(() => debugDesktopOverride = null);
    await startNodes(tester);
    final screen = GlobalKey<ShelfScreenState>();
    await pumpApp(tester, screenKey: screen);
    bool shown(String msg) =>
        tester
            .widget<AnimatedOpacity>(
              find.ancestor(
                of: find.textContaining(msg, findRichText: true),
                matching: find.byType(AnimatedOpacity),
              ),
            )
            .opacity >
        0;
    void look(AppLifecycleState s) =>
        tester.binding.handleAppLifecycleStateChanged(s);
    addTearDown(() => look(AppLifecycleState.resumed));

    // ⌃⌥V pressed in another app with nothing to paste: still there when
    // the user comes back, however long that takes; gone soon after.
    look(AppLifecycleState.inactive);
    screen.currentState!.toast('nothing to paste', untilSeen: true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(shown('nothing to paste'), isTrue);
    look(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 1700));
    expect(shown('nothing to paste'), isTrue, reason: 'its reading time');
    await tester.pump(const Duration(milliseconds: 200));
    expect(shown('nothing to paste'), isFalse);

    // Said while the user is here, it fades as any message does.
    screen.currentState!.toast('nothing to paste', untilSeen: true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(shown('nothing to paste'), isFalse);

    // One with something to tap waits for the tap, back or not.
    look(AppLifecycleState.inactive);
    screen.currentState!.toast(
      'allow plop for Screen Recording',
      action: 'open settings',
      onTap: () {},
      sticky: true,
      untilSeen: true,
    );
    await tester.pump();
    look(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 30));
    expect(shown('allow plop for Screen Recording'), isTrue);

    screen.currentState!.toast(null);
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

    // A message that fits stays on one inline span, the whole message plus
    // the action in two lines. (The test font is wide: 22 glyphs per line
    // here, so this is the longest everyday case it can hold.)
    const usual = 'saved to Downloads/report.pdf';
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

  testWidgets('your own row names the devices that have it', (tester) async {
    debugDesktopOverride = true;
    addTearDown(() => debugDesktopOverride = null);
    await startNodes(tester);
    // Both ways round, so other mirrors what me adds and says so; then a
    // third device joins, after the first receipt so the names keep order.
    late PlopNode third;
    late ShelfItem mine, big;
    await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        final asMe = Peer(
          id: me.id,
          name: 'me',
          hosts: ['127.0.0.1'],
          port: me.port,
        );
        dOther.add(asMe);
        mine = await me.addText('mine');
        await _until(() => mine.receivedBy.contains(other.id), 'receipt');

        final dThird = StaticDiscovery();
        third = await PlopNode.start(
          dir: Directory('${root.path}/third'),
          discovery: dThird,
          name: 'third',
        );
        dThird.add(asMe);
        dMe.add(
          Peer(
            id: third.id,
            name: 'third',
            hosts: ['127.0.0.1'],
            port: third.port,
          ),
        );
        await _until(
          () => me.peers.length == 2 && mine.receivedBy.contains(third.id),
          'third device',
        );

        // Over the eager-copy size, so nobody fetches it until asked to; a
        // sparse file served in place, so it costs nothing to make.
        final file = File('${root.path}/big.bin');
        (await file.open(mode: FileMode.write))
          ..truncateSync(defaultEagerCopyBytes + 1)
          ..closeSync();
        big = await me.addFile(file.path);
        await _until(
          () =>
              [other, third].every((n) => n.items.any((i) => i.key == big.key)),
          'big item listing',
        );
      }, _RealHttp()),
    );
    await pumpApp(tester);
    expect(find.text('you  ·  on other and third'), findsOneWidget);
    expect(find.text('other'), findsOneWidget, reason: "the mirror's row");
    final size = formatSize(big.size);
    expect(
      find.text('$size  ·  you  ·  keep plop open until grabbed'),
      findsOneWidget,
    );

    // One device grabbing a big item does not free the sender: a mirror is
    // never re-served, so the other device still has to fetch it from here.
    Future<void> grab(PlopNode who) async {
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await who.fetch(big.key);
          await _until(() => big.receivedBy.contains(who.id), 'receipt');
        }, _RealHttp()),
      );
      // The receipt reaches the shelf as a microtask of the test's zone,
      // which the first pump runs; the second draws the row.
      await tester.pump();
      await tester.pump();
    }

    await grab(other);
    expect(
      find.text('$size  ·  you  ·  on other  ·  keep plop open until grabbed'),
      findsOneWidget,
    );
    await grab(third);
    expect(find.text('$size  ·  you  ·  on other and third'), findsOneWidget);
    expect(find.textContaining('keep plop open'), findsNothing);

    // Once a peer is gone its name is too; the row keeps the count. A peer
    // leaving is not a shelf change, so the countdown tick redraws it.
    await tester.runAsync(() async {
      dMe.remove(other.id);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    expect(me.peerName(other.id), isNull);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('you  ·  on 2 devices'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(third.stop);
    await stopNodes(tester);
  });

  testWidgets('with nobody nearby, the help is there with rows or without', (
    tester,
  ) async {
    debugDesktopOverride = true;
    addTearDown(() => debugDesktopOverride = null);
    noGrace();
    await startNodes(tester, connect: false);
    await pumpApp(tester);
    const what = 'other device not showing up?';
    expect(find.text('just you'), findsOneWidget);
    expect(find.textContaining('$what\n'), findsOneWidget, reason: 'empty');
    expect(barTip(tester, 'just you'), contains(what));

    // Something on the shelf takes the empty state away; the help moves to
    // a line under the bar rather than going with it.
    await tester.runAsync(() => me.addText('mine'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('mine'), findsOneWidget);
    expect(find.textContaining('$what · '), findsOneWidget);
    expect(barTip(tester, 'just you'), contains(what));

    await stopNodes(tester);
  });

  testWidgets('a device that went quiet sends nobody to their settings', (
    tester,
  ) async {
    debugDesktopOverride = true;
    addTearDown(() => debugDesktopOverride = null);
    noGrace();
    await startNodes(tester);
    await pumpApp(tester);
    expect(find.text('1 nearby'), findsOneWidget);

    // Its phone locks: gone from discovery, its copied text stays.
    await tester.runAsync(() async {
      dMe.remove(other.id);
      await _until(() => me.peers.isEmpty, 'peer down');
    });
    // The news reaches the shelf as a microtask of the test's zone, which
    // the first pump runs; the second draws it.
    await tester.pump();
    await tester.pump();
    expect(find.text('just you'), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
    // No line under the bar that comes and goes with every lock, and no
    // Local Network or firewall steps; the tooltip has the likely reason.
    expect(find.textContaining('not showing up'), findsNothing);
    expect(find.textContaining('asleep'), findsNothing);
    expect(barTip(tester, 'just you'), contains('the other device asleep?'));

    await stopNodes(tester);
  });

  testWidgets("a device that reaches this one but can't be reached is named", (
    tester,
  ) async {
    debugDesktopOverride = true;
    addTearDown(() => debugDesktopOverride = null);
    noGrace();
    await startNodes(
      tester,
      connect: false,
      poll: const Duration(milliseconds: 100),
    );
    // A port nothing listens on stands in for other's firewall: other
    // reaches me, but me never reaches other.
    await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = closed.port;
        await closed.close();
        dOther.add(
          Peer(id: me.id, name: 'me', hosts: ['127.0.0.1'], port: me.port),
        );
        dMe.add(
          Peer(id: other.id, name: 'other', hosts: ['127.0.0.1'], port: port),
        );
        await _until(() => me.unreachable.isNotEmpty, 'unreachable');
      }, _RealHttp()),
    );
    await pumpApp(tester);
    const what = "can't reach other · its firewall is blocking plop";
    const fix = 'plop there says how to let it through';
    expect(find.text('1 unreachable'), findsOneWidget);
    expect(find.text('$what\n$fix'), findsOneWidget, reason: 'empty state');
    expect(find.textContaining('not showing up'), findsNothing);
    expect(barTip(tester, '1 unreachable'), contains('$what\n$fix'));

    // Other goes to sleep: it stops reaching me too, and once its last
    // visit is old it is no longer called blocked. Nothing announces that;
    // the once-a-second check redraws the empty shelf.
    await tester.runAsync(() async {
      dOther.remove(me.id);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      me.server.seenBy[other.id] = DateTime.now().subtract(
        PlopNode.oneWayAfter * 2,
      );
    });
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('just you'), findsOneWidget);
    expect(find.textContaining("can't reach"), findsNothing);

    // Back, and still behind its firewall; then something on the shelf:
    // the same words, on a line under the bar.
    await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        dOther.add(
          Peer(id: me.id, name: 'me', hosts: ['127.0.0.1'], port: me.port),
        );
        await _until(() => me.unreachable.isNotEmpty, 'unreachable again');
      }, _RealHttp()),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1 unreachable'), findsOneWidget);
    await tester.runAsync(() => me.addText('mine'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('$what · $fix'), findsOneWidget);

    await stopNodes(tester);
  });

  testWidgets('a saved row offers to show the file, not another save', (
    tester,
  ) async {
    debugDesktopOverride = true;
    addTearDown(() => debugDesktopOverride = null);
    await startNodes(tester);
    await addFile(tester, 'report.pdf');
    // Downloads, in the test's own folder.
    final downloads = '${root.path}/Downloads';
    debugDownloads = Directory(downloads);
    addTearDown(() => debugDownloads = null);
    await pumpApp(tester);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('report.pdf')));
    await tester.pump();
    String tipOf(IconData icon) => tester
        .widget<Tooltip>(
          find.ancestor(of: find.byIcon(icon), matching: find.byType(Tooltip)),
        )
        .message!;
    expect(tipOf(Icons.arrow_downward_rounded), 'save');
    expect(find.byIcon(Icons.folder_open_rounded), findsNothing);

    // A tap saves it; the row says so, and its icon now shows the file.
    await tester.runAsync(() async {
      await tester.tap(find.text('report.pdf'));
      await _until(
        () => File('$downloads/report.pdf').existsSync(),
        'the save',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.pump();
    expect(
      find.text('${formatSize(1024)}  ·  other  ·  saved'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.arrow_downward_rounded), findsNothing);
    expect(tipOf(Icons.folder_open_rounded), 'show');

    await tester.pump(const Duration(seconds: 5)); // the toast fades
    await stopNodes(tester);
  });

  testWidgets('a lifetime that cannot be saved says so, and holds', (
    tester,
  ) async {
    debugDesktopOverride = true;
    addTearDown(() => debugDesktopOverride = null);
    await startNodes(tester);
    // A settings path under a plain file: creating its directory fails.
    final blocker = File('${root.path}/blocker')..writeAsStringSync('');
    await pumpApp(
      tester,
      settings: Settings.at(File('${blocker.path}/settings.json')),
    );
    await tester.tap(find.text('2m'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5m').last);
    await tester.pumpAndSettle(); // the menu closes; the save starts
    // The save started in the test's fake zone: each of its disk steps
    // needs real time to finish and a pump to be heard.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(me.ttl, const Duration(minutes: 5));
    expect(
      find.text("couldn't save that lifetime · it holds until plop quits"),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 5)); // the toast fades
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

/// Waits up to ten seconds for [done], naming [what] did not happen.
Future<void> _until(bool Function() done, String what) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw '$what did not arrive';
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

class _RealHttp extends HttpOverrides {}
