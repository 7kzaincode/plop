import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:plop_core/plop_core.dart';

import 'seen.dart';
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

  /// What a device brings in this long after plop first hears from it is
  /// what it already had, taken in without a word: a launch at login, with
  /// the window not focused, would otherwise announce everything on the
  /// other devices' shelves as each first syncs.
  static const grace = Duration(seconds: 10);

  /// After [watch], how long a device heard from for the first time still
  /// counts as turning up rather than arriving: at login, Wi-Fi and mDNS
  /// can take a while. One first heard from later is new to this device,
  /// and so are its items.
  static const settle = Duration(minutes: 1);

  static Settings? _settings;
  static bool _ready = false;
  static StreamSubscription<void>? _watching;

  /// Running for [settle] after [watch].
  static Timer? _settling;

  /// Devices heard from since [watch], and those still in their [grace].
  static final _heard = <String>{};
  static final _quiet = <String, Timer>{};

  /// Every item from another device seen so far, so one that comes back
  /// with its peer is not news.
  static final _seen = SeenItems();
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
      await localNotifier.setup(
        appName: 'plop',
        shortcutPolicy: shortcutPolicy(Platform.resolvedExecutable),
      );
      _ready = true;
    } catch (_) {
      // No plugin (a test runner), or Windows had nowhere to put the
      // shortcut; the in-window toasts still say everything.
    }
  }

  /// Windows shows notifications from an unpackaged app only for an
  /// AppUserModelID a Start menu shortcut carries: "plop", which main.cpp
  /// gives the process. The installer's shortcut (all users) carries it, so
  /// an installed plop leaves shortcuts alone; local_notifier's other
  /// "require" policy would look only in the user's own Start menu, not
  /// find it there, and give up. A portable copy, from the zip, has none:
  /// it makes plop.lnk in the user's Start menu, pointing at itself.
  /// Ignored off Windows.
  @visibleForTesting
  static ShortcutPolicy shortcutPolicy(String exe) {
    // Inno Setup leaves its uninstaller next to the copy it installed.
    final uninstaller = File(
      '${File(exe).parent.path}${Platform.pathSeparator}unins000.exe',
    );
    return uninstaller.existsSync()
        ? ShortcutPolicy.ignore
        : ShortcutPolicy.requireCreate;
  }

  /// What a global shortcut did, as the in-window toast says it.
  static void say(String message) {
    if (!_wanted) return;
    _show(title: 'plop', body: message);
  }

  /// The window just closed into the tray, which until now quit plop on
  /// Windows and Linux: the first time, say where it went, focus or not.
  /// Once ever (Settings), and not with notifications switched off.
  static void hiddenToTray() {
    final s = _settings;
    if (!_ready || s == null || !s.notifications || s.trayNoticeShown) return;
    s.trayNoticeShown = true;
    _show(
      title: 'plop is still running in the tray',
      body: 'its icon brings the window back or quits plop',
    );
  }

  /// Call after runApp. Only later arrivals count: what a device had before
  /// plop started comes in with its first sync, within [grace] of plop
  /// first hearing from it, so long as that is within [settle] of launch.
  static void watch(PlopNode node) => watchItems(
    node.changes,
    () => node.items.where((i) => i.originId != node.id),
    () => node.peers.map((p) => p.id),
  );

  /// [watch] with the node taken apart: [changes] fires whenever [remote],
  /// the shelf's items from other devices, or [peers], their ids, may have
  /// changed. A device is heard from when it is found, or failing that when
  /// its first items appear.
  @visibleForTesting
  static void watchItems(
    Stream<void> changes,
    Iterable<ShelfItem> Function() remote,
    Iterable<String> Function() peers,
  ) {
    if (!supported) return;
    _settling?.cancel();
    _settling = Timer(settle, () => _settling = null);
    void check() {
      peers().forEach(_hear);
      arrived(remote());
    }

    check();
    _watching?.cancel();
    _watching = changes.listen((_) => check());
  }

  /// Starts [peer]'s [grace] the first time it is heard from while plop is
  /// settling in.
  static void _hear(String peer) {
    if (_settling == null || !_heard.add(peer)) return;
    _quiet[peer] = Timer(grace, () => _quiet.remove(peer));
  }

  /// The shelf's items from other devices as they are now. New ones are
  /// gathered by sender for [burst] and then announced, one notification
  /// each or, from three up, one "3 items from Zain's iPhone".
  @visibleForTesting
  static void arrived(Iterable<ShelfItem> remote) {
    final here = <String>{};
    for (final item in remote) {
      here.add(item.key);
      _hear(item.originId);
      if (!_seen.add(item)) continue;
      // The row just appeared on a focused shelf: in view already. Or plop
      // just started and this device's shelf is being filled in.
      if (windowFocused || _quiet.containsKey(item.originId)) continue;
      final b = _bursts[item.originId] ??= _Burst(
        item.originName,
        Timer(burst, () => _announce(item.originId)),
      );
      b.items.add(item);
    }
    _seen.prune(here);
  }

  static void _announce(String sender) {
    final b = _bursts.remove(sender);
    // Focused in the meantime, or switched off: the rows are there to see.
    if (b == null || !_wanted) return;
    final items = b.items;
    if (items.length >= 3) {
      _show(
        title: '${items.length} items from ${b.sender}',
        body: items
            .map((i) => i.kind == ItemKind.text ? 'text' : i.name)
            .join(' · '),
      );
      return;
    }
    for (final i in items) {
      _show(title: b.sender, body: describe(i));
    }
  }

  /// What a notification says of one item: its name and size, but of text
  /// only how long it is, or just "text" when that can't be told. Its name
  /// is its first line, and a copied password or sign-in code would
  /// otherwise sit in the notification centre and on the lock screen long
  /// after the item expired.
  @visibleForTesting
  static String describe(ShelfItem i) {
    if (i.kind != ItemKind.text) return '${i.name} · ${formatSize(i.size)}';
    final n = _length(i);
    if (n == null) return 'text';
    return 'text · $n character${n == 1 ? '' : 's'}';
  }

  /// Characters as the reader counts them, from the copy on disk, which a
  /// text has by the end of [burst] as a rule. Null without one, for one
  /// that isn't UTF-8, or one too long to read here: its size in bytes would
  /// be a different number for anything but plain ASCII.
  static int? _length(ShelfItem i) {
    final path = i.path;
    if (path == null || i.size > 64 * 1024) return null;
    try {
      return File(path).readAsStringSync().characters.length;
    } catch (_) {
      return null;
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
    _settling?.cancel();
    _settling = null;
    for (final t in _quiet.values) {
      t.cancel();
    }
    _quiet.clear();
    _heard.clear();
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
