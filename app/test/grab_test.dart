import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plop/grab.dart';
import 'package:plop_core/plop_core.dart';

void main() {
  // Phones' pickers and Share-to-plop hand over a copy in the app cache; the
  // store serves it in place and never deletes it, so addCopy must.
  test('a copy goes with its item, its directory with the last one', () async {
    final root = await Directory.systemTemp.createTemp('plop_copies');
    final node = await PlopNode.start(
      dir: Directory('${root.path}/store'),
      discovery: StaticDiscovery(),
      name: 'me',
    );
    try {
      // Two files from one share land in the same per-share directory.
      final share = Directory('${root.path}/share')..createSync();
      final a = File('${share.path}/a.txt')..writeAsStringSync('a');
      final b = File('${share.path}/b.txt')..writeAsStringSync('b');
      final ia = await addCopy(node, a.path);
      final ib = await addCopy(node, b.path);
      expect(a.existsSync(), isTrue, reason: 'served in place while listed');

      node.remove(ia.key);
      await _until(() => !a.existsSync());
      expect(b.existsSync(), isTrue, reason: 'a sibling still listed');
      expect(share.existsSync(), isTrue);

      node.remove(ib.key);
      await _until(() => !share.existsSync());
    } finally {
      await node.stop();
      await root.delete(recursive: true);
    }
  });

  // Android's clipboard hands over whatever the source app wrote; a wrong
  // extension sends a Windows receiver into a GDI+ copy that fails and
  // leaves a ".png" that is really WebP.
  test('clipboard images are named by what they are', () {
    Uint8List header(List<int> b) =>
        Uint8List.fromList([...b, ...List.filled(16, 0)]);
    expect(imageExt(header([0x89, ...'PNG'.codeUnits])), 'png');
    expect(imageExt(header([0xFF, 0xD8, 0xFF, 0xE0])), 'jpg');
    expect(
      imageExt(header([...'RIFF'.codeUnits, 1, 2, 3, 4, ...'WEBP'.codeUnits])),
      'webp',
    );
    expect(imageExt(header('GIF89a'.codeUnits)), 'gif');
    expect(imageExt(header('BM'.codeUnits)), 'bmp');
    expect(imageExt(header([0, 0, 0, 0x18, ...'ftypheic'.codeUnits])), 'heic');
    expect(imageExt(Uint8List(0)), 'png');
  });
}

Future<void> _until(bool Function() ok) async {
  final end = DateTime.now().add(const Duration(seconds: 2));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
