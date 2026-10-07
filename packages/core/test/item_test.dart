import 'package:plop_core/plop_core.dart';
import 'package:test/test.dart';

void main() {
  test('a peer mime is checked where its list is read', () {
    RemoteItem item(Object? mime) => RemoteItem.fromJson({
      'id': 'a',
      'name': 'a',
      'size': 1,
      'kind': 'file',
      'ttlMs': 1,
      'mime': mime,
    });
    expect(item(null).mime, 'application/octet-stream');
    expect(item(42).mime, 'application/octet-stream');
    expect(item('').mime, 'application/octet-stream');
    expect(item('image/PNG').mime, 'image/png');
    expect(item('image/svg+xml').mime, 'image/svg+xml');
    expect(item('text/plain; charset=utf-8').mime, 'text/plain; charset=utf-8');
    expect(item('text/plain; charset=utf-8\r\nX-A: b').mime, 'text/plain');
    expect(item('text/html\r\nX-A: b').mime, 'application/octet-stream');
    expect(item('text/html\nX').mime, 'application/octet-stream');
    expect(item('text').mime, 'application/octet-stream');
    expect(item('a/b/c').mime, 'application/octet-stream');
    expect(item('text/html, image/png').mime, 'application/octet-stream');
  });

  test('cleanName takes out controls and bidi marks and keeps the tail', () {
    String clean(String s, [int max = 255]) => cleanName(s, max: max);
    expect(clean('invoice\u202Efdp.exe'), 'invoicefdp.exe');
    expect(clean('a\u2066b\u2069\u200Fc\u061C'), 'abc');
    expect(clean(' line\r\nX-Evil: 1\t\u0085 '), 'lineX-Evil: 1');
    expect(clean('\u202E\r\n'), '');
    expect(clean('Zürich 🏔.bin'), 'Zürich 🏔.bin');
    final long = clean('${'a' * 300}.heic');
    expect(long.length, 255);
    expect(long, endsWith('a….heic'));
    // A cut that would fall inside an emoji falls before it.
    final emoji = clean('${'🏔' * 200}.png', 20);
    expect(emoji, '${'🏔' * 7}….png');
    // No extension worth keeping: the head, cut.
    expect(clean('x' * 30, 10), '${'x' * 9}…');
    expect(clean('a.${'x' * 40}', 10), 'a.xxxxxxx…', reason: 'too long a tail');
  });
}
