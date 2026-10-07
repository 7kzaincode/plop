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
