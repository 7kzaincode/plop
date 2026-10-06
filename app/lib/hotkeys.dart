import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:plop_core/plop_core.dart';

import 'grab.dart';

/// System-wide shortcuts on desktop, so things can go on the shelf without
/// switching to plop:
///   ⌃⌥P / Ctrl+Alt+P  select a region of the screen; it lands on the shelf
///   ⌃⌥V / Ctrl+Alt+V  put whatever is on the clipboard on the shelf
abstract final class Hotkeys {
  static final snip = HotKey(
    key: PhysicalKeyboardKey.keyP,
    modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
  );
  static final clip = HotKey(
    key: PhysicalKeyboardKey.keyV,
    modifiers: [HotKeyModifier.control, HotKeyModifier.alt],
  );

  static String get snipLabel => Platform.isMacOS ? '⌃⌥P' : 'ctrl+alt+P';
  static String get clipLabel => Platform.isMacOS ? '⌃⌥V' : 'ctrl+alt+V';

  static bool _busy = false;

  /// [onPlopped] gets a short message after something lands (or fails).
  static Future<void> register(
    PlopNode node,
    void Function(String message) onPlopped,
  ) async {
    if (!isDesktop) return;
    await hotKeyManager.unregisterAll();
    await hotKeyManager.register(
      snip,
      keyDownHandler: (_) => _once(() async {
        final item = await _snipInto(node);
        if (item != null) {
          _pop();
          onPlopped('plopped ${item.name}');
        }
      }, onPlopped),
    );
    await hotKeyManager.register(
      clip,
      keyDownHandler: (_) => _once(() async {
        if (await pasteInto(node)) {
          _pop();
          onPlopped('plopped clipboard');
        } else {
          onPlopped('clipboard is empty');
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
      onPlopped(friendlyError(e));
    } finally {
      _busy = false;
    }
  }

  /// Lets the user drag out a region with the OS's own tool. Returns null if
  /// they cancel.
  static Future<ShelfItem?> _snipInto(PlopNode node) async {
    final name = 'Screenshot ${_stamp()}.png';
    if (Platform.isMacOS) {
      final path = '${outDir.path}/$name';
      // -i: interactive region/window selection (space toggles), -x: silent.
      await Process.run('/usr/sbin/screencapture', ['-i', '-x', path]);
      if (!File(path).existsSync()) return null;
      return node.addFile(path);
    }
    if (Platform.isWindows) {
      // The Snipping Tool overlay puts its result on the clipboard.
      final before = await Pasteboard.image;
      await Process.start('explorer.exe', ['ms-screenclip:']);
      final end = DateTime.now().add(const Duration(minutes: 1));
      while (DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        final now = await Pasteboard.image;
        if (now != null && now.isNotEmpty && !listEquals(now, before)) {
          return node.addBytes(await _toPng(now), name);
        }
      }
      return null;
    }
    // Linux: whichever common tool is installed.
    final path = '${outDir.path}/$name';
    for (final cmd in [
      ['gnome-screenshot', '-a', '-f', path],
      ['spectacle', '-r', '-b', '-n', '-o', path],
      ['scrot', '-s', path],
    ]) {
      try {
        await Process.run(cmd.first, cmd.sublist(1));
        if (File(path).existsSync()) return await node.addFile(path);
      } on ProcessException {
        continue;
      }
    }
    return null;
  }

  static void _pop() {
    if (Platform.isMacOS) {
      Process.run('/usr/bin/afplay', [
        '/System/Library/Sounds/Pop.aiff',
      ]).catchError((_) => ProcessResult(0, 0, '', ''));
    }
  }
}

/// Re-encodes any image Flutter can decode (e.g. the BMP Windows hands back)
/// as PNG.
Future<Uint8List> _toPng(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}

String _stamp() {
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} at '
      '${two(t.hour)}.${two(t.minute)}.${two(t.second)}';
}
