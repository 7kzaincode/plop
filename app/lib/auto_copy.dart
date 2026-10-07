import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:plop_core/plop_core.dart';

import 'grab.dart';
import 'hotkeys.dart' show messageName;
import 'notify.dart';
import 'seen.dart';
import 'settings.dart';

/// Text and pictures another device plops go straight onto this one's
/// clipboard once they are here, when the settings panel has it switched on
/// ([Settings.autoCopy]). Off by default: anyone nearby with plop could then
/// fill the clipboard. Only arrivals count, as with the notifications
/// (lib/notify.dart): not what was on the shelf at launch or what a device
/// brings in its first seconds ([Settling]), nor an item back with a peer
/// that dropped off ([SeenItems]). The newest arrival wins: one still on its
/// way when a newer one comes is skipped, so the clipboard ends up holding
/// the last thing sent. Files and folders never go: they are things to save,
/// not to paste. Nor does anything over the eager-copy size, which is only
/// fetched when someone asks for it. Desktop only.
abstract final class AutoCopy {
  /// Called after each copy instead of the notification, with the item that
  /// is now on the clipboard; the macOS island sets it.
  static void Function(ShelfItem item)? onCopied;

  static Settings? _settings;
  static StreamSubscription<void>? _watching;
  static Future<void> Function(ShelfItem item)? _copy;
  static var _maxBytes = defaultEagerCopyBytes;

  /// Every item from another device seen so far, copied or not.
  static final _seen = SeenItems();
  static final _settling = Settling(grace: Notify.grace, settle: Notify.settle);

  /// The newest arrival waiting for its bytes, by key.
  static String? _pending;

  /// Copies land in the order they started, so an older picture that takes
  /// longer to read never ends up on top of a newer text.
  static Future<void> _copying = Future.value();

  /// Call after runApp. Never throws.
  static void watch(PlopNode node, Settings settings) => watchItems(
    node.changes,
    () => node.items,
    () => node.peers.map((p) => p.id),
    self: node.id,
    settings: settings,
    maxBytes: node.engine.eagerCopyBytes,
    copy: (item) => copyItem(node, item),
  );

  /// [watch] with the node taken apart: [changes] fires whenever [items],
  /// the shelf, or [peers], the ids of the other devices, may have changed;
  /// [self] is this device's id, [copy] puts an item on the clipboard and
  /// [maxBytes] is the eager-copy size.
  @visibleForTesting
  static void watchItems(
    Stream<void> changes,
    Iterable<ShelfItem> Function() items,
    Iterable<String> Function() peers, {
    required String self,
    required Settings settings,
    required Future<void> Function(ShelfItem item) copy,
    int maxBytes = defaultEagerCopyBytes,
  }) {
    if (!isDesktop) return;
    _settings = settings;
    _copy = copy;
    _maxBytes = maxBytes;
    _settling.start();
    void check() {
      peers().forEach(_settling.hear);
      _arrived(items().where((i) => i.originId != self));
    }

    check();
    _watching?.cancel();
    _watching = changes.listen((_) => check());
  }

  static bool get _on => _settings?.autoCopy ?? false;

  /// Text, or a picture this OS's clipboard takes as one ([copiesAsImage]:
  /// none on Linux, no HEIC or WebP on Windows, never SVG), small enough to
  /// have been copied here on sight. A picture the clipboard can't take
  /// would go on it as a file, and files never do.
  static bool _wanted(ShelfItem item) =>
      (item.kind == ItemKind.text || copiesAsImage(item)) &&
      item.size <= _maxBytes;

  /// The shelf's items from other devices as they are now.
  static void _arrived(Iterable<ShelfItem> remote) {
    final items = remote.toList();
    final here = <String>{};
    ShelfItem? newest;
    for (final item in items) {
      here.add(item.key);
      _settling.hear(item.originId);
      if (!_seen.add(item)) continue;
      // Switched off (switching on later does not reach back), a device
      // that is only turning up, or nothing for the clipboard.
      if (!_on || _settling.isQuiet(item.originId) || !_wanted(item)) {
        continue;
      }
      if (newest == null || item.addedAt.isAfter(newest.addedAt)) {
        newest = item;
      }
    }
    _seen.prune(here);
    if (newest != null) _pending = newest.key;
    // Expired and gone, so it is not coming back.
    if (_pending case final key? when !_seen.contains(key)) _pending = null;
    final ready = items
        .where((i) => i.key == _pending && i.isReady)
        .firstOrNull;
    if (ready == null) return;
    _pending = null;
    // An [onCopied] that throws must not stop every copy after it.
    _copying = _copying.then((_) => _land(ready)).catchError((_) {});
  }

  static Future<void> _land(ShelfItem item) async {
    final copy = _copy;
    if (!_on || copy == null) return; // switched off while it was on its way
    try {
      await copy(item);
    } catch (_) {
      // Expired meanwhile, or the clipboard said no: its row is still
      // there to grab by hand.
      return;
    }
    final hook = onCopied;
    if (hook != null) {
      hook(item);
    } else {
      Notify.say('copied ${messageName(item)} from ${item.originName}');
    }
  }

  /// Tests: forget what was seen and set up.
  @visibleForTesting
  static void reset() {
    _watching?.cancel();
    _watching = null;
    _seen.clear();
    _settling.clear();
    _pending = null;
    _copying = Future.value();
    _settings = null;
    _copy = null;
    _maxBytes = defaultEagerCopyBytes;
    onCopied = null;
  }
}
