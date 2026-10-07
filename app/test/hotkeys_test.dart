import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:plop/grab.dart';
import 'package:plop/hotkeys.dart';
import 'package:plop_core/plop_core.dart';

const _s = Duration(seconds: 1);

void main() {
  // Must not depend on PhysicalKeyboardKey.debugName, which is null in
  // release builds (that bug showed every shortcut as "⌃⌥?").
  test('key names come from HID codes', () {
    expect(Hotkeys.keyName(PhysicalKeyboardKey.keyP), 'P');
    expect(Hotkeys.keyName(PhysicalKeyboardKey.keyA), 'A');
    expect(Hotkeys.keyName(PhysicalKeyboardKey.keyZ), 'Z');
    expect(Hotkeys.keyName(PhysicalKeyboardKey.digit1), '1');
    expect(Hotkeys.keyName(PhysicalKeyboardKey.digit0), '0');
    expect(Hotkeys.keyName(PhysicalKeyboardKey.f5), 'F5');
    expect(Hotkeys.keyName(PhysicalKeyboardKey.space), 'Space');
    expect(Hotkeys.keyName(PhysicalKeyboardKey.slash), '/');
  });

  // A system-wide hot key consumes the keystroke before any app sees it, so
  // Shift+S would make capital S untypable and ⌘C would break copy everywhere.
  test('recorder refuses combos that would hijack typing or copy/paste', () {
    HotKey k(PhysicalKeyboardKey key, [List<HotKeyModifier> m = const []]) =>
        HotKey(key: key, modifiers: m);
    final primary = Platform.isMacOS
        ? HotKeyModifier.meta
        : HotKeyModifier.control;
    expect(Hotkeys.reject(k(PhysicalKeyboardKey.keyS)), contains('everywhere'));
    expect(
      Hotkeys.reject(k(PhysicalKeyboardKey.keyS, [HotKeyModifier.shift])),
      contains('everywhere'),
    );
    expect(
      Hotkeys.reject(k(PhysicalKeyboardKey.keyC, [primary])),
      contains('everyday'),
    );
    for (final ok in [
      k(PhysicalKeyboardKey.space, [HotKeyModifier.alt]),
      k(PhysicalKeyboardKey.keyP, [HotKeyModifier.control, HotKeyModifier.alt]),
      k(PhysicalKeyboardKey.keyC, [primary, HotKeyModifier.shift]),
      k(PhysicalKeyboardKey.digit1, [primary]),
      k(PhysicalKeyboardKey.f5),
      k(PhysicalKeyboardKey.f5, [HotKeyModifier.shift]),
      Hotkeys.defaultSnip,
      Hotkeys.defaultClip,
      Hotkeys.defaultGrab,
    ]) {
      expect(Hotkeys.reject(ok), isNull, reason: Hotkeys.label(ok));
    }
  });

  test('the three defaults are three different keys', () {
    final all = Hotkeys.bindings.values.toList();
    expect(all, hasLength(3));
    for (var i = 0; i < all.length; i++) {
      for (var j = i + 1; j < all.length; j++) {
        expect(Hotkeys.same(all[i], all[j]), isFalse);
      }
    }
    expect(Hotkeys.bindings.keys, ['snip', 'clip', 'grab']);
    expect(Hotkeys.grabLabel, Platform.isMacOS ? '⌃⌥G' : 'Ctrl+Shift+Alt+G');
  });

  // Nothing else holds the defaults on a test host; off Windows there is no
  // probe at all, since only Win32 hot keys are exclusive.
  test('the defaults are free to register', () {
    expect(Hotkeys.isFree(Hotkeys.defaultSnip), isTrue);
    expect(Hotkeys.isFree(Hotkeys.defaultClip), isTrue);
    expect(Hotkeys.isFree(Hotkeys.defaultGrab), isTrue);
  }, skip: Platform.isWindows ? false : 'only Windows probes RegisterHotKey');

  group('grab newest', () {
    ShelfItem item(
      String id, {
      String from = 'phone',
      required DateTime added,
    }) => ShelfItem(
      id: id,
      originId: from,
      originName: "Zain's iPhone",
      name: '$id.png',
      size: 1536,
      mime: 'image/png',
      kind: ItemKind.file,
      expiresAt: added.add(const Duration(minutes: 2)),
      ttl: const Duration(minutes: 2),
      addedAt: added,
    );

    // Shelf order is when this device first saw an item, which is what
    // "newest" means; your own, however new, are already here.
    test('takes the newest item from another device, never your own', () {
      final t = DateTime(2026, 10, 7, 12);
      final old = item('old', added: t);
      final newer = item('newer', from: 'mac', added: t.add(_s));
      final mine = item('mine', from: 'me', added: t.add(_s * 2));
      expect(Hotkeys.newestRemote([old, newer, mine], 'me'), same(newer));
      expect(Hotkeys.newestRemote([mine, old, newer], 'me'), same(newer));
      expect(Hotkeys.newestRemote([mine], 'me'), isNull);
      expect(Hotkeys.newestRemote([], 'me'), isNull);
    });

    late Directory root;
    late PlopNode node;
    late List<String> copied, saved;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('plop_grab');
      node = await PlopNode.start(
        dir: Directory('${root.path}/store'),
        discovery: StaticDiscovery(),
        name: 'me',
      );
      copied = [];
      saved = [];
    });

    tearDown(() async {
      await node.stop();
      await root.delete(recursive: true);
    });

    Future<({String message, String? saved})> press() => Hotkeys.grabNewest(
      node,
      copy: (_, i) async {
        copied.add(i.name);
        return 'copied';
      },
      save: (_, i) async {
        saved.add(i.name);
        final sep = Platform.pathSeparator;
        return '${sep}home${sep}Downloads$sep${i.name}';
      },
    );

    /// Puts one item from the phone on [node]'s shelf, as a sync would.
    ShelfItem arrive(String id, String name, ItemKind kind, String mime) =>
        node.store.addRemote(
          'phone',
          "Zain's iPhone",
          RemoteItem(
            id: id,
            name: name,
            size: 1024,
            mime: mime,
            kind: kind,
            ttlMs: 60000,
          ),
        )!;

    test('with nothing from anyone else, says so and grabs nothing', () async {
      await expectLater(
        press(),
        throwsA(
          isA<PlopMessage>().having(
            (e) => e.message,
            'message',
            'nothing new to grab',
          ),
        ),
      );
      await node.addText('my own');
      await expectLater(press(), throwsA(isA<PlopMessage>()));
      expect(copied, isEmpty);
      expect(saved, isEmpty);
    });

    // As the row's copy: text, a picture and any other file go on the
    // clipboard; a folder can't, so it is saved where the row saves it.
    test('text, pictures and files are copied; a folder is saved', () async {
      for (final (id, name, kind, mime, said) in [
        ('t', 'hunter2', ItemKind.text, 'text/plain', 'copied text'),
        (
          'i',
          'IMG_4821.png',
          ItemKind.file,
          'image/png',
          'copied IMG_4821.png',
        ),
        (
          'f',
          'report.pdf',
          ItemKind.file,
          'application/pdf',
          'copied report.pdf',
        ),
      ]) {
        final it = arrive(id, name, kind, mime);
        final r = await press();
        expect(r.message, said);
        expect(r.saved, isNull);
        node.remove(it.key);
      }
      expect(copied, ['hunter2', 'IMG_4821.png', 'report.pdf']);
      expect(saved, isEmpty);

      arrive('d', 'Photos', ItemKind.folder, 'application/zip');
      final r = await press();
      expect(r.message, 'saved Photos to Downloads');
      expect(r.saved, endsWith('Photos'));
      expect(saved, ['Photos']);
      expect(copied, hasLength(3), reason: 'a folder is not copied');
    });
  });

  test('bindings compare by key and modifiers, not label', () {
    HotKey k(PhysicalKeyboardKey key, List<HotKeyModifier> m) =>
        HotKey(key: key, modifiers: m);
    const ca = [HotKeyModifier.control, HotKeyModifier.alt];
    expect(
      Hotkeys.same(
        k(PhysicalKeyboardKey.keyP, ca),
        k(PhysicalKeyboardKey.keyV, ca),
      ),
      isFalse,
    );
    expect(
      Hotkeys.same(
        k(PhysicalKeyboardKey.keyP, ca),
        k(PhysicalKeyboardKey.keyP, ca.reversed.toList()),
      ),
      isTrue,
    );
    expect(
      Hotkeys.same(
        k(PhysicalKeyboardKey.keyP, ca),
        k(PhysicalKeyboardKey.keyP, [...ca, HotKeyModifier.shift]),
      ),
      isFalse,
    );
  });
}
