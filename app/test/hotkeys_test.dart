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
