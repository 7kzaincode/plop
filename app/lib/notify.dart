import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:plop_core/plop_core.dart';

import 'settings.dart';
import 'shelf_screen.dart' show formatSize;
import 'window.dart';

/// OS notifications for what happens while plop is in the background, now
/// that closing the window no longer quits it: what a global shortcut did,
/// and things other devices put on the shelf. Nothing is said while the
/// window is focused, where the toast and the new row are in view anyway,
/// and nothing about your own items or about expiry. A click on a
/// notification brings the window back. Desktop only; the settings panel
/// switches it off ([Settings.notifications]).
abstract final class Notify {
  /// Items from one device within this long of each other are announced
  /// together once there are three or more of them.
  static const burst = Duration(seconds: 2);

  static Settings? _settings;
  static bool _ready = false;
  static final _seen = <String>{};
  static final _bursts = <String, _Burst>{};

  static bool get supported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// Whether the user has the shelf in front of them. On desktop, inactive
  /// means another window has focus and hidden means closed or minimized.
  /// Null is startup, with no state reported yet: the window just opened.
  static bool get windowFocused {
    final s = WidgetsBinding.instance.lifecycleState;
    return s == null || s == AppLifecycleState.resumed;
  }

  static bool get _wanted =>
      _ready && (_settings?.notifications ?? true) && !windowFocused;

  /// Call after runApp. Never throws.
  static Future<void> init(Settings settings) async {
    _settings = settings;
    if (!supported) return;
    try {
      // Windows toasts from an unpackaged app need a Start Menu shortcut
      // carrying its AppUserModelID; local_notifier creates plop.lnk in the
      // user's own Start Menu when it is missing (the installer's is in the
      // all-users one and carries no ID).
      await localNotifier.setup(
        appName: 'plop',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
      _ready = true;
    } catch (_) {
      // No plugin (a test runner), or Windows had nowhere to put the
      // shortcut; the in-window toasts still say everything.
    }
  }

  /// What a global shortcut did, as the in-window toast says it.
  static void say(String message) {
    if (!_wanted) return;
    _show(title: 'plop', body: message);
  }

  /// Call after runApp. What is on the shelf now was put there with the
  /// window up, so only later arrivals count.
  static void watch(PlopNode node) {
    if (!supported) return;
    _seen.addAll([for (final i in node.items) i.key]);
    node.changes.listen((_) => arrived(_remote(node)));
  }

  static Iterable<ShelfItem> _remote(PlopNode node) =>
      node.items.where((i) => i.originId != node.id);

  /// The shelf's items from other devices as they are now. New ones are
  /// gathered by sender for [burst] and then announced, one notification
  /// each or, from three up, one "3 items from Zain's iPhone".
  @visibleForTesting
  static void arrived(Iterable<ShelfItem> remote) {
    final keys = <String>{};
    for (final item in remote) {
      keys.add(item.key);
      if (!_seen.add(item.key)) continue;
      // The row just appeared on a focused shelf: in view already.
      if (windowFocused) continue;
      final b = _bursts[item.originId] ??= _Burst(
        item.originName,
        Timer(burst, () => _announce(item.originId)),
      );
      b.items.add(item);
    }
    _seen.retainAll(keys); // forget expired items
  }

  static void _announce(String sender) {
    final b = _bursts.remove(sender);
    // Focused in the meantime, or switched off: the rows are there to see.
    if (b == null || !_wanted) return;
    final items = b.items;
    if (items.length >= 3) {
      _show(
        title: '${items.length} items from ${b.sender}',
        body: items.map((i) => i.name).join(' · '),
      );
      return;
    }
    for (final i in items) {
      _show(
        title: b.sender,
        body: i.kind == ItemKind.text
            ? i.name
            : '${i.name} · ${formatSize(i.size)}',
      );
    }
  }

  static void _show({required String title, required String body}) {
    final n = LocalNotification(
      title: title,
      body: body,
      // A freedesktop notification reports a click only through an action
      // keyed "default", which servers run on a click and draw no button
      // for. Elsewhere an action would be a button, and a click is reported
      // on its own.
      actions: Platform.isLinux
          ? [LocalNotificationAction(text: 'default')]
          : null,
    );
    void open() {
      AppWindow.show();
      n.destroy().ignore();
    }

    n.onClick = open;
    n.onClickAction = (_) => open();
    // Windows says when a toast was dismissed or timed out; let it go then.
    n.onClose = (_) => localNotifier.removeListener(n);
    n.show().catchError((_) {});
  }

  /// Tests: forget what was seen and set up.
  @visibleForTesting
  static void reset() {
    for (final b in _bursts.values) {
      b.timer.cancel();
    }
    _bursts.clear();
    _seen.clear();
    _ready = false;
    _settings = null;
  }
}

/// New items from one device, waiting out [Notify.burst] together.
class _Burst {
  _Burst(this.sender, this.timer);
  final String sender;
  final Timer timer;
  final items = <ShelfItem>[];
}
