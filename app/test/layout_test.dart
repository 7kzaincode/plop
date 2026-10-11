// Lays the app out at many sizes, desktop and phone, with real fonts. Any
// overflow fails the test. Screenshots land in build/screens/ for review.
//
//   flutter test test/layout_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plop/grab.dart';
import 'package:plop/main.dart';
import 'package:plop/settings.dart';
import 'package:plop/share_in.dart';
import 'package:plop/shelf_screen.dart';
import 'package:plop_core/plop_core.dart';
import 'package:qr_flutter/qr_flutter.dart';

Future<void> _loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final loader = FontLoader(name);
    for (final f in files) {
      loader.addFont(rootBundle.load('assets/fonts/$f'));
    }
    await loader.load();
  }

  await family('Geist', ['Geist-Regular.ttf', 'Geist-Medium.ttf']);
  await family('GeistMono', ['GeistMono-Regular.ttf', 'GeistMono-Medium.ttf']);
  final root = Platform.environment['FLUTTER_ROOT'];
  final icons = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (root != null && icons.existsSync()) {
    final loader = FontLoader('MaterialIcons')
      ..addFont(icons.readAsBytes().then(ByteData.sublistView));
    await loader.load();
  }
}

Future<void> _shot(GlobalKey key, String name) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = File('build/screens/$name.png')..createSync(recursive: true);
  file.writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  late Directory root;
  late PlopNode me, other;
  late StaticDiscovery dMe, dOther;
  late Settings settings;

  setUpAll(() async {
    await _loadFonts();
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  /// [poll] is how often each node polls its peers.
  Future<void> startNodes(
    WidgetTester tester, {
    bool withItems = true,
    Duration poll = const Duration(seconds: 3),
  }) async {
    // flutter_test stubs HttpClient to answer 400; the nodes need the real one.
    await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        root = await Directory.systemTemp.createTemp('plop_layout');
        outDir = Directory('${root.path}/out')..createSync();
        settings = Settings.inMemory();
        dMe = StaticDiscovery();
        dOther = StaticDiscovery();
        me = await PlopNode.start(
          dir: Directory('${root.path}/me'),
          discovery: dMe,
          name: 'This Mac',
          pollInterval: poll,
        );
        me.web.enabled = true; // as on desktop: the panel shows its address
        other = await PlopNode.start(
          dir: Directory('${root.path}/other'),
          discovery: dOther,
          name: "Zain's iPhone 17 Pro Max with a long name",
          eagerCopyBytes: 200 * 1024,
          pollInterval: poll,
        );
        if (!withItems) return;
        dMe.add(
          Peer(
            id: other.id,
            name: "Zain's iPhone",
            hosts: ['127.0.0.1'],
            port: other.port,
          ),
        );
        dOther.add(
          Peer(
            id: me.id,
            name: 'This Mac',
            hosts: ['127.0.0.1'],
            port: me.port,
          ),
        );
        await other.addText(
          'a very long pasted paragraph that goes on and on so the row has '
          'to truncate it somewhere sensible without breaking the layout',
        );
        final logo = await rootBundle.load('assets/brand/logo.png');
        await other.addBytes(logo.buffer.asUint8List(), 'IMG_4821.png');
        await other.addBytes(
          List.filled(300 * 1024, 1),
          'Quarterly report FINAL final v3 (copy) - reviewed by legal team.pdf',
        );
        final folder = Directory('${root.path}/Design system exports 2026');
        File('${folder.path}/a.svg').createSync(recursive: true);
        await other.addPath(folder.path);
        await me.addText('short note');
        final end = DateTime.now().add(const Duration(seconds: 5));
        while (me.items.length < 5 ||
            !me.items.any((i) => i.isReady && i.name == 'IMG_4821.png')) {
          if (DateTime.now().isAfter(end)) throw 'items did not sync';
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }, _RealHttp()),
    );
  }

  Future<void> stopNodes(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await other.stop();
      await me.stop();
      await root.delete(recursive: true);
    });
  }

  Future<GlobalKey> pumpApp(
    WidgetTester tester,
    Size size, {
    GlobalKey<ShelfScreenState>? screenKey,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        // The macOS canvas is translucent; give screenshots a backdrop.
        child: ColoredBox(
          color: const Color(0xFF0A0A0A),
          child: PlopApp(node: me, settings: settings, screenKey: screenKey),
        ),
      ),
    );
    // Let thumbnails decode and entry animations finish.
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    return key;
  }

  const desktopSizes = [
    Size(360, 320),
    Size(460, 560),
    Size(800, 600),
    Size(1200, 800),
  ];
  const phoneSizes = [
    Size(320, 568),
    Size(375, 667),
    Size(430, 932),
    Size(820, 1180),
  ];

  tearDown(() => debugDesktopOverride = null);

  for (final desktop in [true, false]) {
    final kind = desktop ? 'desktop' : 'phone';

    testWidgets('$kind: shelf with items fits at every size', (tester) async {
      debugDesktopOverride = desktop;
      await startNodes(tester);
      for (final size in desktop ? desktopSizes : phoneSizes) {
        final screen = GlobalKey<ShelfScreenState>();
        final key = await pumpApp(tester, size, screenKey: screen);
        expect(tester.takeException(), isNull, reason: '$kind $size');
        final tag = '$kind-items-${size.width.toInt()}x${size.height.toInt()}';
        await tester.runAsync(() => _shot(key, tag));

        if (desktop) {
          // Hover the long-named row so its actions show.
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(
            tester.getCenter(find.textContaining('Quarterly')),
          );
          await tester.pump();
          expect(tester.takeException(), isNull, reason: '$kind $size hover');
          await tester.runAsync(() => _shot(key, '$tag-hover'));
          await mouse.removePointer();
        }

        screen.currentState!.toast(
          'saved to Downloads/Quarterly report FINAL final v3.pdf',
          action: 'show',
          onTap: () {},
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        expect(tester.takeException(), isNull, reason: '$kind $size toast');
        await tester.runAsync(() => _shot(key, '$tag-toast'));
        await tester.pump(const Duration(seconds: 3));
      }
      await stopNodes(tester);
    });

    testWidgets('$kind: empty shelf fits at every size', (tester) async {
      debugDesktopOverride = desktop;
      // Nobody turns up: the empty state ends with what to check.
      peerGrace = Duration.zero;
      addTearDown(() => peerGrace = const Duration(seconds: 6));
      // The phone as on Android, whose share sheets list plop.
      ShareIn.debugShareTarget = true;
      addTearDown(() => ShareIn.debugShareTarget = null);
      await startNodes(tester, withItems: false);
      for (final size in desktop ? desktopSizes : phoneSizes) {
        final key = await pumpApp(tester, size);
        expect(tester.takeException(), isNull, reason: '$kind $size');
        expect(
          find.text('or share to plop from any app'),
          desktop ? findsNothing : findsOneWidget,
        );
        await tester.runAsync(
          () => _shot(
            key,
            '$kind-empty-${size.width.toInt()}x${size.height.toInt()}',
          ),
        );
      }
      await stopNodes(tester);
    });
  }

  for (final desktop in [true, false]) {
    final kind = desktop ? 'desktop' : 'phone';

    // Once the shelf has rows, the empty state's help moves under the bar.
    testWidgets('$kind: the line under the bar fits at every size', (
      tester,
    ) async {
      debugDesktopOverride = desktop;
      peerGrace = Duration.zero;
      addTearDown(() => peerGrace = const Duration(seconds: 6));
      await startNodes(tester, withItems: false);
      await tester.runAsync(() => me.addText('short note'));
      for (final size in desktop ? desktopSizes : phoneSizes) {
        final key = await pumpApp(tester, size);
        expect(tester.takeException(), isNull, reason: '$kind $size');
        expect(find.textContaining('not showing up? · '), findsOneWidget);
        await tester.runAsync(
          () => _shot(
            key,
            '$kind-alone-${size.width.toInt()}x${size.height.toInt()}',
          ),
        );
      }
      await stopNodes(tester);
    });
  }

  for (final desktop in [true, false]) {
    final kind = desktop ? 'desktop' : 'phone';

    // A device whose firewall keeps plop out: the bar's amber count, and
    // the line under it naming the device, as long a name as any.
    testWidgets('$kind: an unreachable device fits at every size', (
      tester,
    ) async {
      debugDesktopOverride = desktop;
      peerGrace = Duration.zero;
      addTearDown(() => peerGrace = const Duration(seconds: 6));
      await startNodes(
        tester,
        withItems: false,
        poll: const Duration(milliseconds: 100),
      );
      const name = "Zain's iPhone 17 Pro Max with a long name";
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          // A port nothing listens on stands in for its firewall: it
          // reaches this Mac, this Mac never reaches it.
          final closed = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final port = closed.port;
          await closed.close();
          dOther.add(
            Peer(
              id: me.id,
              name: 'This Mac',
              hosts: ['127.0.0.1'],
              port: me.port,
            ),
          );
          dMe.add(
            Peer(id: other.id, name: name, hosts: ['127.0.0.1'], port: port),
          );
          await me.addText('short note');
          final end = DateTime.now().add(const Duration(seconds: 5));
          while (me.unreachable.isEmpty) {
            if (DateTime.now().isAfter(end)) throw 'not unreachable';
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }, _RealHttp()),
      );
      for (final size in desktop ? desktopSizes : phoneSizes) {
        final key = await pumpApp(tester, size);
        expect(tester.takeException(), isNull, reason: '$kind $size');
        expect(find.text('1 unreachable'), findsOneWidget);
        expect(
          find.textContaining("can't reach $name · its firewall"),
          findsOneWidget,
        );
        await tester.runAsync(
          () => _shot(
            key,
            '$kind-unreachable-${size.width.toInt()}x${size.height.toInt()}',
          ),
        );
      }
      await stopNodes(tester);
    });
  }

  testWidgets('settings panel fits on small desktop windows', (tester) async {
    debugDesktopOverride = true;
    // Stand in for the Swift side of the login item: macOS holding the item
    // for approval puts the panel's longest note under the toggle.
    const window = MethodChannel('plop/window');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(window, (call) async {
      if (call.method == 'loginItem') return false;
      if (call.method == 'setLoginItem') return 'needsApproval';
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(window, null));
    await startNodes(tester, withItems: false);
    for (final size in const [Size(360, 320), Size(460, 560)]) {
      final key = await pumpApp(tester, size);
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'settings $size');
      final tag =
          'desktop-settings-${size.width.toInt()}x${size.height.toInt()}';
      await tester.runAsync(() => _shot(key, tag));

      // The web shelf's address is looked up off the UI thread (scutil, the
      // network interfaces); give it real time, then the QR code and the
      // lines under it must fit the panel's width and scroll into view. The
      // lookup of plop.local gives up after 1.5 s where no computer holds
      // it, on the test's clock.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 400)),
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      final qr = find.byType(QrImageView);
      expect(qr, findsOneWidget);
      await tester.ensureVisible(qr);
      await tester.pumpAndSettle();
      // The .local name first; the next address (an IPv4) under it.
      final urls = (await tester.runAsync(() => me.webUrls))!;
      final address = urls.first;
      final url = find.text(address);
      expect(url, findsOneWidget);
      if (urls.length > 1) expect(find.text('or ${urls[1]}'), findsOneWidget);
      expect(
        tester.getSize(url).width,
        lessThanOrEqualTo(tester.getSize(find.byType(Dialog)).width),
      );
      await tester.ensureVisible(find.text('then share › add to home screen'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'settings $size phone');
      await tester.runAsync(() => _shot(key, '$tag-phone'));

      // A tap copies the address, and the line says so for a moment.
      String? copied;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      // The private mode section below makes the panel longer; bring the
      // address back into view first.
      await tester.ensureVisible(url);
      await tester.pumpAndSettle();
      await tester.tap(url);
      await tester.pump();
      expect(copied, address);
      expect(find.text('copied'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(address), findsOneWidget);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);

      // The background section sits below the fold at the smallest size:
      // it must scroll into view, not overflow.
      final notifications = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'show arrivals',
      );
      expect(find.text('when plop is in the background'), findsOneWidget);
      await tester.ensureVisible(notifications);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'settings $size bottom');
      await tester.runAsync(() => _shot(key, '$tag-background'));

      // Only macOS goes through the mocked channel; elsewhere the toggle
      // would edit the real OS. With the note the panel is taller than the
      // smallest window: it must scroll to the note, not overflow.
      if (Platform.isMacOS) {
        final toggle = find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.label == 'open plop at login' &&
              w.properties.toggled == false,
        );
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        final note = find.textContaining('approve plop in System Settings');
        expect(note, findsOneWidget);
        await tester.ensureVisible(note);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'settings $size note');
        await tester.runAsync(() => _shot(key, '$tag-note'));
      }
      // Scrolled away by now, under the phone and background sections.
      await tester.ensureVisible(find.text('snip a screen region'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('snip a screen region').hitTestable().first);
      await tester.tapAt(const Offset(5, 5)); // close the dialog
      await tester.pumpAndSettle();
    }
    await stopNodes(tester);
  });

  test('sizes format compactly', () {
    expect(formatSize(0), '0 B');
    expect(formatSize(1536), '1.5 KB');
    expect(formatSize(25 * 1024 * 1024), '25 MB');
  });
}

class _RealHttp extends HttpOverrides {}
