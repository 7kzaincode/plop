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
      RepaintBoundary(key: shot, child: PlopApp(node: me)),
    );
    expect(find.textContaining('Anyone on this Wi-Fi'), findsOneWidget);

    // Peer adds a text and a file over the eager-copy cap.
    await other.addText('hello from the other laptop');
    final bigName = 'big-${DateTime.now().millisecondsSinceEpoch}.bin';
    final big = File('${tmp.path}/$bigName');
    await big.writeAsBytes(List.filled(defaultEagerCopyBytes + 1024, 42));
    await other.addFile(big.path);
    await me.addText('something of mine');

    await waitFor(tester, find.text('hello from the other laptop'));
    await waitFor(tester, find.text(bigName));
    await waitFor(tester, find.text('1 device nearby'));
    expect(find.textContaining('from Other Laptop'), findsNWidgets(2));
    expect(find.textContaining('from You'), findsOneWidget);

    // Big item was listed but not copied yet.
    final bigItem = me.items.firstWhere((i) => i.name == bigName);
    expect(bigItem.isReady, isFalse);

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

    // Tap text: copied to the clipboard.
    await tester.tap(find.text('hello from the other laptop'));
    await waitFor(tester, find.text('Copied'));
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    expect(clip?.text, 'hello from the other laptop');

    // Tap big file: fetched on demand and saved to Downloads.
    if (isDesktop) {
      await tester.tap(find.text(bigName));
      await waitFor(tester, find.textContaining('Saved to'));
      final saved = File('${(await getDownloadsDirectory())!.path}/$bigName');
      expect(await saved.length(), defaultEagerCopyBytes + 1024);
      await saved.delete();
    }
    await big.delete();
  });
}
