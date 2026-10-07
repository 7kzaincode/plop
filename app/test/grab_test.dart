import 'dart:io';

import 'package:flutter/services.dart';
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

  // A drop on the window and one on the Dock icon both go through this;
  // a path that fails must not keep the rest off the shelf.
  test('adding paths carries on past one that fails, and says so', () async {
    final root = await Directory.systemTemp.createTemp('plop_paths');
    final node = await PlopNode.start(
      dir: Directory('${root.path}/store'),
      discovery: StaticDiscovery(),
      name: 'me',
    );
    try {
      final a = File('${root.path}/a.txt')..writeAsStringSync('a');
      final folder = Directory('${root.path}/Photos')..createSync();
      File('${folder.path}/b.txt').writeAsStringSync('b');
      final told = <String?>[];
      final (failed, first) = await addPaths(node, [
        '${root.path}/gone.txt',
        a.path,
        folder.path,
      ], packing: told.add);
      expect(failed, 1);
      expect(first, isA<FileSystemException>());
      expect(
        node.items.map((i) => i.name),
        unorderedEquals(['a.txt', 'Photos']),
      );
      expect(told, ['Photos', null], reason: 'a folder is packed, then done');

      expect(addedMessage(0, null), isNull);
      expect(addedMessage(1, first), "can't access gone.txt");
      expect(addedMessage(3, first), "can't access gone.txt · 2 more failed");
    } finally {
      await node.stop();
      await root.delete(recursive: true);
    }
  });

  // The messages are the whole UI for a failed grab; the core's exceptions
  // must each land on their own line, not the catch-all.
  test('errors are told apart by type and message', () {
    expect(friendlyError(const PlopMessage('as is')), 'as is');
    expect(
      friendlyError(const FormatException('folder zip is compressed')),
      "that folder isn't something plop made",
    );
    expect(friendlyError(StateError('item expired')), 'that one expired');
    expect(
      friendlyError(StateError('sender is gone')),
      'the sender is no longer reachable',
    );
    expect(friendlyError(const SocketException('refused')), contains('sender'));
    expect(
      friendlyError(const TransferInterrupted(HttpException('closed'))),
      contains('sender'),
    );
    expect(
      friendlyError(const FileSystemException('x', '/tmp/a/report.pdf.part')),
      "can't access report.pdf",
    );
    expect(friendlyError(Object()), "that didn't work");
  });

  // A row's copy, the grab shortcut and copying arrivals all go by this;
  // a picture it says no to goes on the clipboard as a file, or not at all.
  test('which pictures each clipboard takes as a picture', () {
    addTearDown(() => debugClipboardOs = null);
    ShelfItem pic(String name, [int size = 1024]) => ShelfItem(
      id: 'x',
      originId: 'phone',
      originName: 'phone',
      name: name,
      size: size,
      mime: 'application/octet-stream',
      kind: ItemKind.file,
      expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      ttl: const Duration(minutes: 1),
    );
    final names = ['a.png', 'b.JPG', 'c.gif', 'd.heic', 'e.webp', 'f.svg'];
    for (final (os, want) in [
      ('macos', ['a.png', 'b.JPG', 'c.gif', 'd.heic', 'e.webp']),
      ('ios', ['a.png', 'b.JPG', 'c.gif', 'd.heic', 'e.webp']),
      ('windows', ['a.png', 'b.JPG', 'c.gif']),
      ('android', ['a.png', 'b.JPG', 'c.gif']),
      ('linux', <String>[]),
    ]) {
      debugClipboardOs = os;
      expect(
        [
          for (final n in names)
            if (copiesAsImage(pic(n))) n,
        ],
        want,
        reason: os,
      );
    }
    debugClipboardOs = 'android';
    expect(copiesAsImage(pic('big.png', 26 << 20)), isFalse);
    expect(copiesAsImage(pic('notes.pdf')), isFalse);
  });

  // On a Mac, pasteboard writes a blank picture for bytes ImageIO can't
  // read and reports success; the copy must find out first.
  testWidgets('a picture that does not decode is never copied as one', (
    tester,
  ) async {
    debugClipboardOs = 'macos';
    addTearDown(() => debugClipboardOs = null);
    final images = <Object?>[], files = <Object?>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    const pasteboard = MethodChannel('pasteboard');
    messenger.setMockMethodCallHandler(pasteboard, (call) async {
      if (call.method == 'writeImage') images.add(call.arguments);
      if (call.method == 'writeFiles') files.add(call.arguments);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(pasteboard, null));

    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('plop_copy');
      outDir = Directory('${root.path}/out')..createSync();
      final node = await PlopNode.start(
        dir: Directory('${root.path}/store'),
        discovery: StaticDiscovery(),
        name: 'me',
      );
      try {
        final logo = await rootBundle.load('assets/brand/logo.png');
        final good = await node.addBytes(logo.buffer.asUint8List(), 'a.png');
        expect(await copyItem(node, good), 'image copied');

        images.clear();
        final bad = await node.addBytes(List.filled(64, 7), 'b.png');
        expect(await copyItem(node, bad), 'copied · paste it anywhere');
        expect(images, isEmpty, reason: 'no blank picture on the clipboard');
        expect(files, hasLength(1), reason: 'the file instead');

        // Copying arrivals puts no file on the clipboard: it fails.
        await expectLater(
          copyItem(node, bad, orFile: false),
          throwsA(isA<PlopMessage>()),
        );
        expect(images, isEmpty);
        expect(files, hasLength(1));
      } finally {
        await node.stop();
        await root.delete(recursive: true);
      }
    });
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
    expect(imageExt(header([0, 0, 0, 0x1c, ...'ftypavif'.codeUnits])), 'avif');
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
