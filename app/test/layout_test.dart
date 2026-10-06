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
import 'package:plop/shelf_screen.dart';
import 'package:plop_core/plop_core.dart';

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
  late Settings settings;

  setUpAll(() async {
    await _loadFonts();
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  Future<void> startNodes(WidgetTester tester, {bool withItems = true}) async {
    // flutter_test stubs HttpClient to answer 400; the nodes need the real one.
    await tester.runAsync(
      () => HttpOverrides.runWithHttpOverrides(() async {
        root = await Directory.systemTemp.createTemp('plop_layout');
        outDir = Directory('${root.path}/out')..createSync();
        settings = Settings.inMemory();
        final dMe = StaticDiscovery(), dOther = StaticDiscovery();
        me = await PlopNode.start(
          dir: Directory('${root.path}/me'),
          discovery: dMe,
          name: 'This Mac',
        );
        other = await PlopNode.start(
          dir: Directory('${root.path}/other'),
          discovery: dOther,
          name: "Zain's iPhone 17 Pro Max with a long name",
          eagerCopyBytes: 200 * 1024,
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
      await startNodes(tester, withItems: false);
      for (final size in desktop ? desktopSizes : phoneSizes) {
        final key = await pumpApp(tester, size);
        expect(tester.takeException(), isNull, reason: '$kind $size');
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

  test('sizes format compactly', () {
    expect(formatSize(0), '0 B');
    expect(formatSize(1536), '1.5 KB');
    expect(formatSize(25 * 1024 * 1024), '25 MB');
  });
}

class _RealHttp extends HttpOverrides {}
