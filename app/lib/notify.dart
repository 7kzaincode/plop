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

  /// After [watch], arrivals are taken in without a word for this long: a
  /// launch at login, with the window not focused, would otherwise announce
  /// everything already on the other devices' shelves as it first syncs.
  static const grace = Duration(seconds: 10);

  static Settings? _settings;
  static bool _ready = false;
  static Timer? _grace;
  static StreamSubscription<void>? _watching;

  /// Every item from another device seen so far, with when it may be
  /// forgotten: its expiry, once it has left the shelf too. A peer that
  /// drops off for a moment (a missed poll, a phone asleep) takes its
  /// uncopied items with it and brings them back; they are not new then.
  static final _seen = <String, DateTime>{};
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

  /// Call after runApp. Only later arrivals count: what is on the shelf now,
  /// and what the first sync brings within [grace], was on the other
  /// devices before plop started.
  static void watch(PlopNode node) => watchItems(
    node.changes,
    () => node.items.where((i) => i.originId != node.id),
  );

  /// [watch] with the node taken apart: [changes] fires whenever [remote],
  /// the shelf's items from other devices, may have changed.
  @visibleForTesting
  static void watchItems(
    Stream<void> changes,
    Iterable<ShelfItem> Function() remote,
  ) {
    if (!supported) return;
    _grace?.cancel();
    _grace = Timer(grace, () => _grace = null);
    arrived(remote());
    _watching?.cancel();
    _watching = changes.listen((_) => arrived(remote()));
  }

  /// The shelf's items from other devices as they are now. New ones are
  /// gathered by sender for [burst] and then announced, one notification
  /// each or, from three up, one "3 items from Zain's iPhone".
  @visibleForTesting
  static void arrived(Iterable<ShelfItem> remote) {
    final now = DateTime.now();
    final here = <String>{};
    for (final item in remote) {
      here.add(item.key);
      final until = _seen[item.key];
      if (until == null || item.expiresAt.isAfter(until)) {
        _seen[item.key] = item.expiresAt;
      }
      if (until != null) continue;
      // The row just appeared on a focused shelf: in view already. Or plop
      // just started, and the shelf is being filled in.
      if (windowFocused || _grace != null) continue;
      final b = _bursts[item.originId] ??= _Burst(
        item.originName,
        Timer(burst, () => _announce(item.originId)),
      );
      b.items.add(item);
    }
    // Forget what has both expired and left. One still here past its expiry
    // (a transfer holds it) stays seen.
    _seen.removeWhere(
      (key, until) => until.isBefore(now) && !here.contains(key),
    );
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

  /// Tests: the keys still remembered as seen.
  @visibleForTesting
  static Iterable<String> get debugSeen => _seen.keys;

  /// Tests: forget what was seen and set up.
  @visibleForTesting
  static void reset() {
    for (final b in _bursts.values) {
      b.timer.cancel();
    }
    _bursts.clear();
    _seen.clear();
    _grace?.cancel();
    _grace = null;
    _watching?.cancel();
    _watching = null;
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
