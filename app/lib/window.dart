import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:plop_core/plop_core.dart';

/// The macOS window draws its own title bar area (see MainFlutterWindow.swift).
abstract final class MacWindow {
  static const _channel = MethodChannel('plop/window');

  /// Height of the title bar the content runs under; 0 elsewhere.
  static double titlebar = 0;

  static Future<void> init() async {
    if (!Platform.isMacOS) return;
    try {
      titlebar = await _channel.invokeMethod<double>('titlebar') ?? 32;
    } catch (_) {
      titlebar = 32;
    }
    if (titlebar < 28) titlebar = 32;
  }

  static void drag() => _channel.invokeMethod<void>('drag').ignore();
  static void zoom() => _channel.invokeMethod<void>('zoom').ignore();

  /// Brings the window to the front, reopening it if it was closed, for a
  /// message the user must act on while they are in another app.
  static void show() {
    if (Platform.isMacOS) _channel.invokeMethod<void>('show').ignore();
  }
}

/// Something from another device landed while plop was closed or behind
/// other windows: a count on the Dock icon (macOS, MainFlutterWindow.swift
/// "badge") or a flashing taskbar button (Windows, flutter_window.cpp
/// "flash"), cleared once the window is focused again. Linux has no
/// portable equivalent.
abstract final class Arrivals {
  static const _channel = MethodChannel('plop/window');
  static final _seen = <String>{};
  static var _unseen = 0;

  /// Call after runApp: it needs the widgets binding, which also keeps the
  /// lifecycle listener alive.
  static void watch(PlopNode node) {
    if (!Platform.isMacOS && !Platform.isWindows) return;
    node.changes.listen((_) => _update(node));
    AppLifecycleListener(onResume: () => _update(node));
  }

  static void _update(PlopNode node) {
    final remote = {
      for (final i in node.items)
        if (i.originId != node.id) i.key,
    };
    // Focused, or not told yet (startup): the shelf is in view, so all of it
    // counts as seen. On desktop, inactive means another window has focus
    // and hidden means closed or minimized.
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) {
      _seen.addAll(remote);
    }
    _seen.retainAll(remote); // forget expired items
    final unseen = remote.difference(_seen).length;
    if (unseen == _unseen) return;
    final fresh = unseen > _unseen;
    _unseen = unseen;
    if (Platform.isMacOS) {
      _channel.invokeMethod<void>('badge', {
        'count': unseen,
        'fresh': fresh,
      }).ignore();
    } else if (fresh) {
      _channel.invokeMethod<void>('flash').ignore();
    }
  }
}
