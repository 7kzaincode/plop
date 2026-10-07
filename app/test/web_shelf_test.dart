import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plop/web_shelf.dart';
import 'package:qr_flutter/qr_flutter.dart';

void main() {
  test('the quiet zone is four modules or more at every likely size', () {
    // Versions 1 to 10: 21 to 57 modules, far past any address plop shows.
    for (var modules = 21; modules <= 57; modules += 4) {
      final quiet = qrQuietZone(modules, ShelfQr.size);
      final module = (ShelfQr.size - 2 * quiet) / modules;
      // Whole half pixels, which qr_flutter keeps as they are.
      expect(module * 2, (module * 2).roundToDouble(), reason: '$modules');
      expect(module, greaterThanOrEqualTo(2), reason: '$modules');
      expect(quiet, greaterThanOrEqualTo(4 * module), reason: '$modules');
      // The code itself still gets most of the card.
      expect(
        module * modules,
        greaterThan(0.7 * ShelfQr.size),
        reason: '$modules',
      );
    }
  });

  testWidgets('the QR code is black on a white card, quiet zone and all', (
    tester,
  ) async {
    const url = 'http://zains-macbook-pro-5.local:7567/';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: ShelfQr(url)),
        ),
      ),
    );
    final card = tester.widget<Container>(
      find
          .ancestor(
            of: find.byType(QrImageView),
            matching: find.byType(Container),
          )
          .first,
    );
    expect((card.decoration! as BoxDecoration).color, Colors.white);
    expect(
      tester.getSize(find.byType(QrImageView)),
      const Size(ShelfQr.size, ShelfQr.size),
    );
    final qr = tester.widget<QrImageView>(find.byType(QrImageView));
    expect(qr.eyeStyle.color, Colors.black);
    expect(qr.dataModuleStyle.color, Colors.black);
    expect(qr.backgroundColor, Colors.transparent, reason: 'the card is white');
    final modules = QrValidator.validate(
      data: url,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.L,
    ).qrCode!.moduleCount;
    final module = (ShelfQr.size - qr.padding.horizontal) / modules;
    expect(qr.padding.left, greaterThanOrEqualTo(4 * module));
    expect(qr.padding.top, qr.padding.left);
  });
}
