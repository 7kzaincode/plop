import 'dart:async';

import 'package:plop_core/plop_core.dart';

/// Items from other devices already seen (announced, or in view on the
/// shelf), each kept until it has both expired and left. A peer that drops
/// off for a moment (a missed poll, a phone asleep) takes its uncopied items
/// with it and brings them back; they are not new then. One held past its
/// expiry by a transfer stays seen while it is still on the shelf. Shared by
/// the notifications (lib/notify.dart) and the Dock badge / taskbar flash
/// (Arrivals, lib/window.dart).
class SeenItems {
  final _until = <String, DateTime>{};

  bool contains(String key) => _until.containsKey(key);

  /// The keys remembered now.
  Iterable<String> get keys => _until.keys;

  /// Remembers [item] until its expiry, or the later one it was seen with.
  /// Whether it was new.
  bool add(ShelfItem item) {
    final until = _until[item.key];
    if (until == null || item.expiresAt.isAfter(until)) {
      _until[item.key] = item.expiresAt;
    }
    return until == null;
  }

  /// Forgets what has expired and is not in [here], the keys on the shelf.
  void prune(Set<String> here) {
    final now = DateTime.now();
    _until.removeWhere((k, until) => until.isBefore(now) && !here.contains(k));
  }

  void clear() => _until.clear();
}

/// Which devices are still in their first moments, so what they bring is
/// what they already had rather than news: at a launch at login the other
/// devices' shelves fill in over the first seconds, as each first syncs.
/// A device gets [grace] from when plop first hears from it, so long as
/// that is within [settle] of [start]: at login, Wi-Fi and mDNS can take a
/// while. One first heard from later is new to this device, and so are its
/// items. Copying arrivals (lib/auto_copy.dart) keeps time with this; the
/// notifications (lib/notify.dart) keep the same time with their own.
class Settling {
  Settling({required this.grace, required this.settle});

  final Duration grace;
  final Duration settle;

  /// Running for [settle] after [start].
  Timer? _settling;

  /// Devices heard from since [start], and those still in their [grace].
  final _heard = <String>{};
  final _quiet = <String, Timer>{};

  /// Plop starts watching: devices heard from in the next [settle] are
  /// turning up, not arriving.
  void start() {
    _settling?.cancel();
    _settling = Timer(settle, () => _settling = null);
  }

  /// Starts [peer]'s [grace] the first time it is heard from while plop is
  /// settling in.
  void hear(String peer) {
    if (_settling == null || !_heard.add(peer)) return;
    _quiet[peer] = Timer(grace, () => _quiet.remove(peer));
  }

  /// Whether what [peer] brings now is what it already had.
  bool isQuiet(String peer) => _quiet.containsKey(peer);

  /// Forgets every device and stops the clock, as before [start].
  void clear() {
    _settling?.cancel();
    _settling = null;
    for (final t in _quiet.values) {
      t.cancel();
    }
    _quiet.clear();
    _heard.clear();
  }
}
