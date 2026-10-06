import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plop/grab.dart';

void main() {
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
