import 'package:flutter_test/flutter_test.dart';
import 'package:plop/updates.dart';

void main() {
  test('newer compares versions number by number', () {
    expect(newer('0.2.9', '0.2.8'), isTrue);
    expect(newer('0.10.0', '0.9.9'), isTrue, reason: 'not as text');
    expect(newer('v1.0.0', '0.2.8'), isTrue, reason: 'a tag name');
    expect(newer('0.2.8', '0.2.8'), isFalse);
    expect(newer('0.2.7', '0.2.8'), isFalse);
    expect(newer('0.2.9', 'dev'), isFalse, reason: 'a dev build stays put');
    expect(newer('dev-build', '0.2.8'), isFalse);
  });
}
