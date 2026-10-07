// Copying arrivals to the clipboard (lib/auto_copy.dart), with a list
// standing in for the clipboard and a stream for the node's changes.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plop/auto_copy.dart';
import 'package:plop/grab.dart';
import 'package:plop/notify.dart';
import 'package:plop/settings.dart';
import 'package:plop_core/plop_core.dart';

void main() {
  late StreamController<void> changes;
  late List<ShelfItem> shelf;
  late List<String> peers;
  late List<String> copied; // names, in the order they reached the clipboard
  late List<String> told; // names onCopied was called with
  late Settings settings;

  // Pictures copy as pictures here, as on a Mac, whatever runs the tests.
  setUp(() => debugClipboardOs = 'macos');
  tearDown(() => debugClipboardOs = null);

  /// Starts watching an empty shelf, switched on unless [on] is false, with
  /// the phone and the Mac already found and their first seconds over, so
  /// what they plop from here on is an arrival.
  Future<void> start(WidgetTester tester, {bool on = true}) async {
    AutoCopy.reset();
    changes = StreamController<void>.broadcast();
    shelf = [];
    peers = ['phone', 'mac'];
    copied = [];
    told = [];
    settings = Settings.inMemory()..autoCopy = on;
    AutoCopy.onCopied = (item) => told.add(item.name);
    AutoCopy.watchItems(
      changes.stream,
      () => shelf,
      () => peers,
      self: 'me',
      settings: settings,
      maxBytes: 1 << 20,
      copy: (item) async => copied.add(item.name),
    );
    await tester.pump(Notify.grace);
  }

  /// The shelf changed; let the watcher look.
  Future<void> changed(WidgetTester tester) async {
    changes.add(null);
    await tester.pump();
  }

  /// Ends a test with no timer left running.
  Future<void> stop() async {
    AutoCopy.reset();
    await changes.close();
  }

  ShelfItem item(
    String name, {
    String from = 'phone',
    ItemKind kind = ItemKind.text,
    int size = 12,
    bool ready = false,
    DateTime? added,
  }) => ShelfItem(
    id: name.replaceAll(RegExp('[^A-Za-z0-9]'), '_'),
    originId: from,
    originName: from == 'mac' ? 'Studio' : "Zain's iPhone",
    name: name,
    size: size,
    mime: 'application/octet-stream',
    kind: kind,
    expiresAt: DateTime.now().add(const Duration(minutes: 2)),
    ttl: const Duration(minutes: 2),
    addedAt: added,
    path: ready ? '/tmp/$name' : null,
  );

  testWidgets('off by default; switched on, only later arrivals go', (
    tester,
  ) async {
    expect(Settings.inMemory().autoCopy, isFalse);
    await start(tester, on: false);
    final before = item('before', ready: true);
    shelf = [before];
    await changed(tester);
    expect(copied, isEmpty);

    // Switched on: what arrived while it was off stays where it is.
    settings.autoCopy = true;
    await changed(tester);
    expect(copied, isEmpty);
    shelf = [item('after', ready: true), before];
    await changed(tester);
    expect(copied, ['after']);
    await stop();
  });

  testWidgets('a text from another device goes on once it is here, once', (
    tester,
  ) async {
    await start(tester);
    final text = item('hunter2');
    shelf = [text];
    await changed(tester);
    expect(copied, isEmpty, reason: 'its bytes are not here yet');

    text.path = '/tmp/hunter2'; // the eager copy lands
    await changed(tester);
    expect(copied, ['hunter2']);
    expect(told, ['hunter2'], reason: 'the island hears of it');

    await changed(tester);
    shelf = [item('note.pdf', kind: ItemKind.file, ready: true), text];
    await changed(tester);
    expect(copied, ['hunter2'], reason: 'once, and not for a file');
    await stop();
  });

  testWidgets('your own items are never copied', (tester) async {
    await start(tester);
    shelf = [item('mine', from: 'me', ready: true)];
    await changed(tester);
    expect(copied, isEmpty);
    await stop();
  });

  testWidgets("what was there at launch, or in a device's first seconds, "
      'stays put', (tester) async {
    AutoCopy.reset();
    changes = StreamController<void>.broadcast();
    copied = [];
    settings = Settings.inMemory()..autoCopy = true;
    shelf = [item('at launch', ready: true)];
    peers = ['phone'];
    AutoCopy.watchItems(
      changes.stream,
      () => shelf,
      () => peers,
      self: 'me',
      settings: settings,
      copy: (item) async => copied.add(item.name),
    );
    await tester.pump();
    expect(copied, isEmpty);

    // The Mac turns up a few seconds in, its shelf as it was.
    await tester.pump(const Duration(seconds: 3));
    shelf = [...shelf, item('on the mac', from: 'mac', ready: true)];
    await changed(tester);
    expect(copied, isEmpty);

    // Its grace is over: what it plops now is an arrival.
    await tester.pump(Notify.grace);
    shelf = [...shelf, item('new', from: 'mac', ready: true)];
    await changed(tester);
    expect(copied, ['new']);

    // Once plop has settled in, a device first heard from is new, and so
    // is everything it has.
    await tester.pump(Notify.settle);
    shelf = [...shelf, item('from the pad', from: 'pad', ready: true)];
    await changed(tester);
    expect(copied, ['new', 'from the pad']);
    await stop();
  });

  testWidgets('an item back with a peer that dropped off is not copied again', (
    tester,
  ) async {
    await start(tester);
    shelf = [item('hello', ready: true)];
    await changed(tester);
    expect(copied, ['hello']);

    // A missed poll: the phone's rows go, then come back as new mirrors.
    shelf = [];
    await changed(tester);
    shelf = [item('hello', ready: true)];
    await changed(tester);
    expect(copied, ['hello']);
    await stop();
  });

  testWidgets('the newest arrival wins over one still on its way', (
    tester,
  ) async {
    await start(tester);
    final older = item('older');
    shelf = [older];
    await changed(tester);
    final newer = item('newer', from: 'mac');
    shelf = [newer, older];
    await changed(tester);

    older.path = '/tmp/older';
    await changed(tester);
    expect(copied, isEmpty, reason: 'a newer one is coming');
    newer.path = '/tmp/newer';
    await changed(tester);
    expect(copied, ['newer']);

    // Two in one sync: the later of them.
    final t = DateTime.now();
    shelf = [
      item('second', ready: true, added: t.add(const Duration(seconds: 1))),
      item('first', ready: true, added: t),
      ...shelf,
    ];
    await changed(tester);
    expect(copied, ['newer', 'second']);
    await stop();
  });

  testWidgets('files, folders, SVGs and big items are never copied', (
    tester,
  ) async {
    await start(tester);
    shelf = [
      item('report.pdf', kind: ItemKind.file, ready: true),
      item('Photos', kind: ItemKind.folder, ready: true),
      item('logo.svg', kind: ItemKind.file, ready: true),
      item('huge.png', kind: ItemKind.file, size: 2 << 20, ready: true),
      item('long text', size: 2 << 20, ready: true),
    ];
    await changed(tester);
    expect(copied, isEmpty);

    // A picture of a usual size does go.
    shelf = [item('IMG_4821.png', kind: ItemKind.file, ready: true), ...shelf];
    await changed(tester);
    expect(copied, ['IMG_4821.png']);
    await stop();
  });

  // A picture the clipboard can't take as one would go on it as a file,
  // copied in full to a scratch folder: none on Linux, and on Windows only
  // what GDI+ reads.
  testWidgets('only pictures that copy as pictures', (tester) async {
    for (final (os, want) in [
      ('linux', <String>[]),
      ('windows', ['a.jpg', 'b.png']),
      ('macos', ['a.jpg', 'b.png', 'c.webp', 'd.heic']),
    ]) {
      debugClipboardOs = os;
      await start(tester);
      for (final name in ['a.jpg', 'b.png', 'c.webp', 'd.heic']) {
        shelf = [item(name, kind: ItemKind.file, ready: true), ...shelf];
        await changed(tester);
      }
      expect(copied, want, reason: os);
      await stop();
    }
  });

  testWidgets('a hook that throws does not stop the copies after it', (
    tester,
  ) async {
    await start(tester);
    AutoCopy.onCopied = (_) => throw StateError('island gone');
    shelf = [item('one', ready: true)];
    await changed(tester);
    shelf = [item('two', ready: true), ...shelf];
    await changed(tester);
    expect(copied, ['one', 'two']);
    await stop();
  });

  testWidgets('switched off while on its way, it stays put', (tester) async {
    await start(tester);
    final text = item('later');
    shelf = [text];
    await changed(tester);
    settings.autoCopy = false;
    text.path = '/tmp/later';
    await changed(tester);
    expect(copied, isEmpty);
    await stop();
  });
}
