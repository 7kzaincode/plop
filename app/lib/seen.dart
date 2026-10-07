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

/// Which devices are only turning up, so what they bring is what they
/// already had rather than news, and when. A device gets [grace] from when
/// it turns up:
///   - heard from for the first time within [settle] of [start]: at a
///     launch at login the other devices' shelves fill in over the first
///     seconds, and Wi-Fi and mDNS can take a while;
///   - back on the network after more than [away] gone, or after any
///     absence while settling: its shelf filled up while it was out of
///     reach (a phone out of the house, a laptop asleep);
///   - heard from when this machine wakes from sleep, which [start]s
///     settling again: what the others plopped meanwhile is not arriving
///     now.
/// One first heard from once plop has settled in is new to this device,
/// and so are its items. Copying arrivals (lib/auto_copy.dart) keeps time
/// with this; the notifications (lib/notify.dart) keep their own, for
/// launch only.
class Settling {
  Settling({
    required this.grace,
    required this.settle,
    this.away = const Duration(minutes: 1),
    DateTime Function()? now,
    Stopwatch? monotonic,
  }) : _now = now ?? DateTime.now,
       _mono = monotonic ?? (Stopwatch()..start());

  final Duration grace;
  final Duration settle;
  final Duration away;

  /// How often the clocks are compared when nothing else asks ([check]).
  static const tick = Duration(seconds: 15);

  final DateTime Function() _now;

  /// Sleep shows as the wall clock running ahead of a monotonic one, which
  /// stands still while the machine sleeps; App Nap delays timers but runs
  /// both clocks alike, so it is not mistaken for sleep.
  final Stopwatch _mono;
  DateTime? _wall;
  Duration _monoAt = Duration.zero;

  /// Running for [settle] after [start].
  Timer? _settling;
  Timer? _ticking;

  /// Devices heard from since [start], and those still in their [grace].
  final _heard = <String>{};
  final _quiet = <String, Timer>{};

  /// Devices on the network at the last [present], and those that have
  /// left since, each with a timer that runs out once it has been [away].
  var _here = <String>{};
  final _gone = <String, Timer>{};

  /// Plop starts watching, or the machine woke: devices heard from in the
  /// next [settle] are turning up, not arriving.
  void start() {
    _settling?.cancel();
    _settling = Timer(settle, () => _settling = null);
    _heard.clear();
    _mark();
    _ticking ??= Timer.periodic(tick, (_) => check());
  }

  void _mark() {
    _wall = _now();
    _monoAt = _mono.elapsed;
  }

  /// Whether the machine slept since the last look; call it before taking
  /// in what the network says, so what came in while asleep is not news.
  /// On waking, every device already on the shelf starts its [grace] at
  /// once (one that left and comes back gets one from [present]), and
  /// devices heard from for the first time in the next [settle] get one.
  void check() {
    final wall = _wall;
    final ran = _mono.elapsed - _monoAt,
        passed = wall == null ? ran : _now().difference(wall);
    _mark();
    if (passed - ran <= away) return;
    _settling?.cancel();
    _settling = Timer(settle, () => _settling = null);
    for (final p in {..._here, ..._heard}) {
      _quietFor(p);
    }
  }

  /// Starts [peer]'s [grace] the first time it is heard from while plop is
  /// settling in.
  void hear(String peer) {
    if (_settling == null || !_heard.add(peer)) return;
    _quietFor(peer);
  }

  /// The devices on the network now. One back after long enough away, or
  /// while settling, starts a [grace]; one seen for the first time is
  /// left to [hear].
  void present(Iterable<String> peers) {
    final now = peers.toSet();
    for (final p in now.difference(_here)) {
      final gone = _gone.remove(p);
      if (gone == null) continue;
      final long = !gone.isActive;
      gone.cancel();
      if (long || _settling != null) _quietFor(p);
    }
    for (final p in _here.difference(now)) {
      _gone[p] = Timer(away, () {});
    }
    _here = now;
  }

  void _quietFor(String peer) {
    _quiet[peer]?.cancel();
    _quiet[peer] = Timer(grace, () => _quiet.remove(peer));
  }

  /// Whether what [peer] brings now is what it already had.
  bool isQuiet(String peer) => _quiet.containsKey(peer);

  /// Forgets every device and stops the clocks, as before [start].
  void clear() {
    for (final t in [_settling, _ticking, ..._quiet.values, ..._gone.values]) {
      t?.cancel();
    }
    _settling = _ticking = null;
    _wall = null;
    _quiet.clear();
    _gone.clear();
    _heard.clear();
    _here = {};
  }
}
