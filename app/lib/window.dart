import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:plop_core/plop_core.dart';

import 'island.dart';
import 'notify.dart';
import 'seen.dart';

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
  static void show() => AppWindow.show();
}

/// The desktop window as a whole: brought back from the tray or a
/// notification, hidden, or plop quit, through the runners' "plop/window"
/// channel (MainFlutterWindow.swift, flutter_window.cpp, my_application.cc).
abstract final class AppWindow {
  static const _channel = MethodChannel('plop/window');

  static bool get supported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// Brings the window to the front, reopening it if it was closed and out
  /// of the Dock or taskbar if minimized.
  static void show() {
    if (supported) _channel.invokeMethod<void>('show').ignore();
  }

  /// Puts the window away with plop still running, as its close button
  /// does once the tray icon is up.
  static void hide() {
    if (supported) _channel.invokeMethod<void>('hide').ignore();
  }

  /// Windows and Linux: whether closing the window hides it, with plop
  /// living on in the tray, or quits plop as it did before there was a tray
  /// icon. Off until lib/tray.dart has the icon up, so a close can never
  /// leave plop running with no way back to it. macOS always keeps running
  /// (AppDelegate.swift); its Dock icon reopens the window.
  static Future<void> hideOnClose(bool on) async {
    if (!Platform.isWindows && !Platform.isLinux) return;
    try {
      await _channel.invokeMethod<void>('hideOnClose', on);
    } catch (_) {
      // An older runner without the handler: closing quits, as before.
    }
  }

  /// Ends plop: the runner quits from its own message loop once it has
  /// answered. Should it have no handler, or plop still be running two
  /// seconds later, the process exits anyway: "quit plop" must always quit.
  static Future<void> quit() async {
    try {
      await _channel.invokeMethod<void>('quit');
    } catch (_) {
      exit(0);
    }
    Timer(const Duration(seconds: 2), () => exit(0));
  }
}

/// Something from another device landed while plop was closed or behind
/// other windows: a count on the Dock icon (macOS, MainFlutterWindow.swift
/// "badge") or a flashing taskbar button (Windows, flutter_window.cpp
/// "flash"), cleared once the window is focused again. Linux has no
/// portable equivalent. Where the island says what arrived, the Dock icon
/// doesn't bounce and the taskbar button doesn't flash on top of it.
abstract final class Arrivals {
  static const _channel = MethodChannel('plop/window');

  /// What was on a focused shelf, so an item that comes back with its peer
  /// is not counted as fresh again.
  static final _seen = SeenItems();
  static var _unseen = 0;

  /// Call after runApp: it needs the widgets binding, which also keeps the
  /// lifecycle listener alive.
  static void watch(PlopNode node) {
    if (!Platform.isMacOS && !Platform.isWindows) return;
    node.changes.listen((_) => _update(node));
    AppLifecycleListener(onResume: () => _update(node));
  }

  static void _update(PlopNode node) =>
      // A phone's upload through the web shelf is news from elsewhere too.
      update(
        node.items.where(
          (i) => i.originId != node.id || node.web.isUpload(i.key),
        ),
      );

  /// The shelf's items from other devices as they are now.
  @visibleForTesting
  static void update(Iterable<ShelfItem> remote) {
    final items = remote.toList();
    final here = {for (final i in items) i.key};
    // Focused, or not told yet (startup): the shelf is in view, so all of it
    // counts as seen. On desktop, inactive means another window has focus
    // and hidden means closed or minimized.
    final state = WidgetsBinding.instance.lifecycleState;
    final inView = state == null || state == AppLifecycleState.resumed;
    for (final i in items) {
      if (inView || _seen.contains(i.key)) _seen.add(i);
    }
    _seen.prune(here);
    final unseen = here.where((k) => !_seen.contains(k)).length;
    if (unseen == _unseen) return;
    final fresh = unseen > _unseen;
    _unseen = unseen;
    if (Platform.isMacOS) {
      _channel.invokeMethod<void>('badge', {
        'count': unseen,
        // The island says what arrived now; no bounce on top of it.
        'fresh': fresh && !Island.active,
      }).ignore();
    } else if (fresh && !(Island.active && Notify.islandWanted)) {
      // The pill says what arrived now. With it switched off ("show
      // arrivals") the taskbar button still flashes, as it always did
      // alongside the notifications that switch also turns off.
      _channel.invokeMethod<void>('flash').ignore();
    }
  }

  /// Tests: forget what was seen.
  @visibleForTesting
  static void reset() {
    _seen.clear();
    _unseen = 0;
  }
}
