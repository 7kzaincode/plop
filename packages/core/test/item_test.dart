import 'dart:io';

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

  test('cleanName is safeLabel on one trimmed line, keeping the tail', () {
    String clean(String s, [int max = 255]) => cleanName(s, max: max);
    expect(clean('invoice\u202Efdp.exe'), 'invoice_fdp.exe');
    expect(clean('a\u2066b\u2069\u200Fc\u061C'), 'a_b_c');
    expect(clean(' line\r\nX-Evil: 1\t\u0085 '), 'line__X-Evil: 1__');
    expect(isBlankLabel('\u202E \r\n\u200F'), isTrue);
    expect(isBlankLabel('_'), isFalse);
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

  test('a list entry says how old the item is; a mirror keeps it', () async {
    final added = DateTime.now().subtract(const Duration(seconds: 90));
    final own = ShelfItem(
      id: 'a1',
      originId: 'me',
      originName: 'Mac',
      name: 'notes.txt',
      size: 3,
      mime: 'text/plain',
      kind: ItemKind.file,
      expiresAt: added.add(const Duration(minutes: 2)),
      ttl: const Duration(minutes: 2),
      addedAt: added,
    );
    final json = own.toJson();
    expect(json['ageMs'] as int, inInclusiveRange(89000, 92000));

    final remote = RemoteItem.fromJson(json);
    expect(remote.ageMs, json['ageMs']);
    // Older nodes leave it out; nonsense is unknown, not trusted.
    for (final odd in [null, -5, 'x', 1e300]) {
      final r = RemoteItem.fromJson({...json, 'ageMs': odd});
      expect(r.ageMs, isNull, reason: '$odd');
    }

    final dir = Directory.systemTemp.createTempSync('plop_age');
    final store = ShelfStore(nodeId: 'me', nodeName: 'Mac', dir: dir);
    addTearDown(() async {
      await store.dispose();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final mirror = store.addRemote('peer', 'Phone', remote)!;
    expect(mirror.ageAtArrival!.inSeconds, inInclusiveRange(89, 92));
    final old = store.addRemote(
      'peer',
      'Phone',
      RemoteItem.fromJson({...json, 'id': 'b2', 'ageMs': null}),
    )!;
    expect(old.ageAtArrival, isNull);
  });
}
