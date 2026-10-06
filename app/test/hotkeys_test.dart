import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:plop/hotkeys.dart';

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
    ]) {
      expect(Hotkeys.reject(ok), isNull, reason: Hotkeys.label(ok));
    }
  });

  // Nothing else holds the defaults on a test host; off Windows there is no
  // probe at all, since only Win32 hot keys are exclusive.
  test('the defaults are free to register', () {
    expect(Hotkeys.isFree(Hotkeys.defaultSnip), isTrue);
    expect(Hotkeys.isFree(Hotkeys.defaultClip), isTrue);
  }, skip: Platform.isWindows ? false : 'only Windows probes RegisterHotKey');

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
