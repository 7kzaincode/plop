// End to end on a real device/desktop: real Bonjour, real HTTP, real UI.
//
//   flutter test integration_test -d macos
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:plop/bonsoir_discovery.dart';
import 'package:plop/grab.dart';
import 'package:plop/main.dart';
import 'package:plop/settings.dart';
import 'package:plop_core/plop_core.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> waitFor(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final end = DateTime.now().add(timeout);
    while (finder.evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) {
        fail('timed out waiting for $finder');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    }
  }

  testWidgets('a peer found over Bonjour shows up and can be grabbed', (
    tester,
  ) async {
    final tmp = await getTemporaryDirectory();
    outDir = Directory('${tmp.path}/it-out')..createSync(recursive: true);
    final me = await PlopNode.start(
      dir: Directory('${tmp.path}/it-me'),
      discovery: BonsoirPeerDiscovery(),
      name: 'Test Mac',
    );
    final other = await PlopNode.start(
      dir: Directory('${tmp.path}/it-other'),
      discovery: BonsoirPeerDiscovery(),
      name: 'Other Laptop',
    );
    addTearDown(() async {
      await other.stop();
      await me.stop();
    });

    final shot = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: shot,
        child: PlopApp(node: me, settings: await Settings.load()),
      ),
    );
    expect(find.textContaining('to paste'), findsOneWidget);

    final stamp = DateTime.now().millisecondsSinceEpoch;
    await other.addText('hello from the other laptop');
    final logo = await rootBundle.load('assets/brand/logo.png');
    await other.addBytes(logo.buffer.asUint8List(), 'screenshot.png');
    final folder = Directory('${tmp.path}/Folder $stamp');
    File('${folder.path}/a/notes.md').createSync(recursive: true);
    File('${folder.path}/a/notes.md').writeAsStringSync('# hi');
    await other.addPath(folder.path);
    final bigName = 'big-$stamp.zip';
    final big = File('${tmp.path}/$bigName');
    await big.writeAsBytes(List.filled(defaultEagerCopyBytes + 1024, 42));
    await other.addFile(big.path);
    await me.addText('something of mine');

    await waitFor(tester, find.text('hello from the other laptop'));
    await waitFor(tester, find.text(bigName));
    await waitFor(tester, find.text('Folder $stamp'));
    await waitFor(tester, find.textContaining(RegExp(r'^\d+ nearby$')));
    // Let the eager copy of the image finish so its thumbnail shows.
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (!me.items.any((i) => i.name == 'screenshot.png' && i.isReady)) {
      if (DateTime.now().isAfter(end)) fail('image was not copied eagerly');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    await tester.pump();

    final bigItem = me.items.firstWhere((i) => i.name == bigName);
    expect(bigItem.isReady, isFalse, reason: 'over the eager cap');

    // Let entry animations and the thumbnail decode finish.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.runAsync(() async {
      final boundary =
          shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final out = File('${tmp.path}/plop-screenshot.png');
      await out.writeAsBytes(png!.buffer.asUint8List());
      // ignore: avoid_print
      print('SCREENSHOT ${out.path}');
    });

    // Text: tap copies.
    await tester.tap(find.text('hello from the other laptop'));
    await waitFor(tester, find.text('copied'));
    expect(
      (await Clipboard.getData(Clipboard.kTextPlain))?.text,
      'hello from the other laptop',
    );

    if (isDesktop) {
      final downloads = (await getDownloadsDirectory())!.path;

      // Image: tap copies the image itself.
      await tester.tap(find.text('screenshot.png'));
      await waitFor(tester, find.text('image copied'));

      // Folder: tap saves and unpacks into Downloads.
      await tester.tap(find.text('Folder $stamp'));
      await waitFor(tester, find.textContaining('saved to'));
      final saved = Directory('$downloads/Folder $stamp');
      expect(File('${saved.path}/a/notes.md').readAsStringSync(), '# hi');
      await saved.delete(recursive: true);

      // Big file: fetched on demand straight into Downloads.
      await tester.tap(find.text(bigName));
      await waitFor(tester, find.textContaining('saved to Downloads'));
      final file = File('$downloads/$bigName');
      expect(await file.length(), defaultEagerCopyBytes + 1024);
      await file.delete();
    }
    await big.delete();
    await folder.delete(recursive: true);
  });
}
