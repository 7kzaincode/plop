import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:plop_core/plop_core.dart';

import 'grab.dart';

/// System-wide shortcuts on desktop, so things can go on the shelf without
/// switching to plop. The defaults, which the user can rebind:
///   ⌃⌥P / Ctrl+Shift+Alt+P  select a region of the screen; it lands on the shelf
///   ⌃⌥V / Ctrl+Shift+Alt+V  put whatever is on the clipboard on the shelf
/// Windows and Linux add Shift: Ctrl+Alt alone is AltGr on many layouts and
/// clashes with Office and JetBrains shortcuts.
abstract final class Hotkeys {
  static final defaultMods = Platform.isMacOS
      ? const [HotKeyModifier.control, HotKeyModifier.alt]
      : const [
          HotKeyModifier.control,
          HotKeyModifier.shift,
          HotKeyModifier.alt,
        ];
  static final defaultSnip = HotKey(
    key: PhysicalKeyboardKey.keyP,
    modifiers: defaultMods,
  );
  static final defaultClip = HotKey(
    key: PhysicalKeyboardKey.keyV,
    modifiers: defaultMods,
  );

  static HotKey snip = defaultSnip;
  static HotKey clip = defaultClip;

  static String get snipLabel => label(snip);
  static String get clipLabel => label(clip);

  /// ⌃⌥⇧⌘P on macOS, Ctrl+Shift+Alt+P elsewhere.
  static String label(HotKey k) {
    final mods = k.modifiers ?? const <HotKeyModifier>[];
    final order = Platform.isMacOS
        ? const [
            (HotKeyModifier.control, '⌃'),
            (HotKeyModifier.alt, '⌥'),
            (HotKeyModifier.shift, '⇧'),
            (HotKeyModifier.meta, '⌘'),
          ]
        : const [
            (HotKeyModifier.control, 'Ctrl+'),
            (HotKeyModifier.shift, 'Shift+'),
            (HotKeyModifier.alt, 'Alt+'),
            (HotKeyModifier.meta, 'Win+'),
          ];
    return [
      for (final (m, s) in order)
        if (mods.contains(m)) s,
      keyName(k.physicalKey),
    ].join();
  }

  /// Whether two bindings are the same key with the same modifiers.
  static bool same(HotKey a, HotKey b) =>
      a.physicalKey == b.physicalKey &&
      {...?a.modifiers}.containsAll({...?b.modifiers}) &&
      {...?b.modifiers}.containsAll({...?a.modifiers});

  /// A key's printed name from its USB HID usage code. PhysicalKeyboardKey's
  /// debugName is null in release builds, so it can't be used for this.
  static String keyName(PhysicalKeyboardKey key) {
    final u = key.usbHidUsage;
    if (u >= 0x00070004 && u <= 0x0007001d) {
      return String.fromCharCode(0x41 + u - 0x00070004); // A-Z
    }
    if (u >= 0x0007001e && u <= 0x00070026) {
      return '${u - 0x0007001e + 1}'; // 1-9
    }
    if (u >= 0x0007003a && u <= 0x00070045) {
      return 'F${u - 0x0007003a + 1}'; // F1-F12
    }
    return _keyNames[u] ?? '#${(u & 0xffff).toRadixString(16)}';
  }

  static const _keyNames = {
    0x00070027: '0',
    0x00070028: '↩',
    0x0007002a: '⌫',
    0x0007002b: '⇥',
    0x0007002c: 'Space',
    0x0007002d: '-',
    0x0007002e: '=',
    0x0007002f: '[',
    0x00070030: ']',
    0x00070031: r'\',
    0x00070033: ';',
    0x00070034: "'",
    0x00070035: '`',
    0x00070036: ',',
    0x00070037: '.',
    0x00070038: '/',
    0x0007004a: 'Home',
    0x0007004b: 'PgUp',
    0x0007004c: 'Del',
    0x0007004d: 'End',
    0x0007004e: 'PgDn',
    0x0007004f: '→',
    0x00070050: '←',
    0x00070051: '↓',
    0x00070052: '↑',
  };

  static PlopNode? _node;
  static void Function(String message)? _onPlopped;

  /// Global shortcuts only work on X11 under Linux, not Wayland.
  static bool get supported =>
      isDesktop &&
      !(Platform.isLinux &&
          (Platform.environment['XDG_SESSION_TYPE'] == 'wayland' ||
              (Platform.environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty));

  static bool _busy = false;
  static int _snipGen = 0;
  static bool _askedForScreen = false;

  /// [onPlopped] gets a short message after something lands (or fails).
  static Future<void> register(
    PlopNode node,
    void Function(String message) onPlopped,
  ) async {
    _node = node;
    _onPlopped = onPlopped;
    await apply();
  }

  /// Stops listening, e.g. while the user records a new binding.
  static Future<void> pause() async {
    if (supported) await hotKeyManager.unregisterAll();
  }

  /// (Re)registers the current bindings.
  static Future<void> apply() async {
    final node = _node, onPlopped = _onPlopped;
    if (!supported || node == null || onPlopped == null) return;
    await hotKeyManager.unregisterAll();
    await hotKeyManager.register(
      snip,
      keyDownHandler: (_) {
        Future<void> run() async {
          final item = await _snipInto(node);
          if (item != null) {
            _feedback(true);
            onPlopped('plopped ${item.name}');
          }
        }

        // The Windows snip waits on the user, so it must not hold the lock
        // that the other shortcut shares.
        if (Platform.isWindows) {
          run().catchError((Object e) {
            _feedback(false);
            onPlopped(friendlyError(e));
          });
        } else {
          _once(run, onPlopped);
        }
      },
    );
    await hotKeyManager.register(
      clip,
      keyDownHandler: (_) => _once(() async {
        if (await pasteInto(node)) {
          _feedback(true);
          onPlopped('plopped clipboard');
        } else {
          _feedback(false);
          onPlopped('nothing to paste');
        }
      }, onPlopped),
    );
  }

  static Future<void> _once(
    Future<void> Function() f,
    void Function(String) onPlopped,
  ) async {
    if (_busy) return;
    _busy = true;
    try {
      await f();
    } catch (e) {
      _feedback(false);
      onPlopped(friendlyError(e));
    } finally {
      _busy = false;
    }
  }

  /// Lets the user drag out a region with the OS's own tool. Returns null if
  /// they cancel.
  static Future<ShelfItem?> _snipInto(PlopNode node) async {
    final name = 'Screenshot ${_dateStamp()}.png';
    final path = '${outDir.path}${Platform.pathSeparator}$name';
    if (Platform.isMacOS) {
      _checkScreenAccess();
      // -i: interactive region/window selection (space toggles), -x: silent.
      await Process.run('/usr/sbin/screencapture', ['-i', '-x', path]);
      return _addAndDelete(node, path, name);
    }
    if (Platform.isWindows) return _snipWindows(node, name);
    // Linux: the first tool that launches decides; a cancel means stop.
    for (final cmd in [
      ['gnome-screenshot', '-a', '-f', path],
      ['spectacle', '-r', '-b', '-n', '-o', path],
      ['scrot', '-s', path],
    ]) {
      try {
        await Process.run(cmd.first, cmd.sublist(1));
      } on ProcessException {
        continue; // not installed
      }
      return _addAndDelete(node, path, name);
    }
    throw const PlopMessage('install gnome-screenshot, spectacle or scrot');
  }

  /// Owned bytes, so the screenshot is deleted when it expires.
  static Future<ShelfItem?> _addAndDelete(
    PlopNode node,
    String path,
    String name,
  ) async {
    final f = File(path);
    if (!f.existsSync()) return null;
    final bytes = await f.readAsBytes();
    await f.delete();
    return node.addBytes(bytes, name);
  }

  /// Without Screen Recording permission, screencapture silently saves only
  /// the wallpaper and menu bar.
  static void _checkScreenAccess() {
    final cg = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
    );
    bool call(String fn) =>
        cg.lookupFunction<Bool Function(), bool Function()>(fn)();
    if (call('CGPreflightScreenCaptureAccess')) return;
    // The first request shows the system prompt; later ones return false
    // silently, so open the settings pane instead.
    if (!_askedForScreen) {
      _askedForScreen = true;
      if (call('CGRequestScreenCaptureAccess')) return;
      throw const PlopMessage(
        'allow plop for Screen Recording, then quit plop (⌘Q) and reopen it',
      );
    }
    Process.run('/usr/bin/open', [
      'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
    ]);
    // A switch that is already on usually belongs to an older build of plop,
    // which macOS treats as a different app.
    throw PlopMessage(
      "plop isn't allowed yet · if it's already switched on, remove it with −, "
      'press $snipLabel again, allow it, then reopen plop',
    );
  }

  /// The Snipping Tool overlay puts its result on the clipboard. Watch the
  /// clipboard's sequence number rather than its contents, so nothing is read
  /// until it changes; a newer press cancels this wait.
  static Future<ShelfItem?> _snipWindows(PlopNode node, String name) async {
    final seqOf = DynamicLibrary.open('user32.dll')
        .lookupFunction<Uint32 Function(), int Function()>(
          'GetClipboardSequenceNumber',
        );
    final gen = ++_snipGen;
    final start = seqOf();
    await Process.start('explorer.exe', ['ms-screenclip:']);
    final end = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(end) && gen == _snipGen) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (seqOf() == start) continue;
      // Another process may still hold the clipboard for a moment.
      for (var tries = 0; tries < 10; tries++) {
        try {
          final image = await Pasteboard.image;
          if (image == null || image.isEmpty) return null; // not an image
          return await addImageBytes(node, image, prefix: 'Screenshot');
        } on PlatformException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      return null;
    }
    return null;
  }

  static void _feedback(bool ok) {
    if (ok && Platform.isMacOS) {
      Process.run('/usr/bin/afplay', [
        '/System/Library/Sounds/Pop.aiff',
      ]).ignore();
    } else if (!ok) {
      SystemSound.play(SystemSoundType.alert);
    }
  }
}

String _dateStamp() {
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} at ${stamp()}';
}
