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
}
