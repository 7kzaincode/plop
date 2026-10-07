import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard;
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
///
/// An arrival is copied only soon after it arrives, and only over what was
/// on the clipboard then: one not here within its eager-copy deadline (a
/// slow sender, a retry minutes later, or a save from its row, which also
/// brings it here) is let go, and one that finds the user has copied
/// something since leaves that alone ([clipboardStamp]).
abstract final class AutoCopy {
  /// Called after each copy instead of the notification, with the item that
  /// is now on the clipboard; the macOS island sets it.
  static void Function(ShelfItem item)? onCopied;

  static Settings? _settings;
  static StreamSubscription<void>? _watching;
  static Future<void> Function(ShelfItem item)? _copy;
  static Future<Object?> Function() _stamp = clipboardStamp;
  static Duration Function(int bytes) _deadline = _eagerDeadline;
  static var _maxBytes = defaultEagerCopyBytes;

  /// Every item from another device seen so far, copied or not.
  static final _seen = SeenItems();
  static final _settling = Settling(grace: Notify.grace, settle: Notify.settle);

  /// The newest arrival waiting for its bytes, with the clipboard as it
  /// was when it arrived and the time it has to get here.
  static _Pending? _pending;

  /// Copies land in the order they started, so an older picture that takes
  /// longer to read never ends up on top of a newer text.
  static Future<void> _copying = Future.value();

  /// The clipboard as auto-copy's own last copy left it: that copy is not
  /// the user copying something since a later arrival came.
  static Object? _ours;

  /// Call after runApp. Never throws.
  static void watch(PlopNode node, Settings settings) => watchItems(
    node.changes,
    () => node.items,
    () => node.peers.map((p) => p.id),
    self: node.id,
    settings: settings,
    maxBytes: node.engine.eagerCopyBytes,
    deadline: node.engine.eagerDeadlineFor,
    copy: (item) => copyItem(node, item),
  );

  /// [watch] with the node taken apart: [changes] fires whenever [items],
  /// the shelf, or [peers], the ids of the other devices, may have changed;
  /// [self] is this device's id, [copy] puts an item on the clipboard,
  /// [maxBytes] is the eager-copy size and [deadline] the time an eager
  /// copy of a size gets. [stamp] stands in for [clipboardStamp].
  @visibleForTesting
  static void watchItems(
    Stream<void> changes,
    Iterable<ShelfItem> Function() items,
    Iterable<String> Function() peers, {
    required String self,
    required Settings settings,
    required Future<void> Function(ShelfItem item) copy,
    int maxBytes = defaultEagerCopyBytes,
    Duration Function(int bytes)? deadline,
    Future<Object?> Function()? stamp,
  }) {
    if (!isDesktop) return;
    _settings = settings;
    _copy = copy;
    _maxBytes = maxBytes;
    _deadline = deadline ?? _eagerDeadline;
    _stamp = stamp ?? clipboardStamp;
    _settling.start();
    void check() {
      peers().forEach(_settling.hear);
      _arrived(items().where((i) => i.originId != self));
    }

    check();
    _watching?.cancel();
    _watching = changes.listen((_) => check());
  }

  static Duration _eagerDeadline(int bytes) =>
      defaultEagerDeadline +
      Duration(milliseconds: bytes * 1000 ~/ (256 << 10));

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
    if (newest != null) _wait(newest);
    final pending = _pending;
    if (pending == null) return;
    // Removed by its sender, or gone with its device: should it come back,
    // it is not new.
    if (!here.contains(pending.key)) {
      _letGo();
      return;
    }
    final ready = items.firstWhere((i) => i.key == pending.key);
    if (!ready.isReady) return;
    _letGo();
    // An [onCopied] that throws must not stop every copy after it.
    _copying = _copying
        .then((_) => _land(ready, pending.stamp))
        .catchError((_) {});
  }

  /// [item] is the one to copy once it is here, so long as that is within
  /// its eager-copy deadline.
  static void _wait(ShelfItem item) {
    _letGo();
    final key = item.key;
    _pending = (
      key: key,
      stamp: _readStamp(),
      timer: Timer(_deadline(item.size), () {
        if (_pending?.key == key) _pending = null;
      }),
    );
  }

  static void _letGo() {
    _pending?.timer.cancel();
    _pending = null;
  }

  /// [_stamp], or null for a clipboard that can't be read.
  static Future<Object?> _readStamp() =>
      Future.sync(_stamp).then((s) => s, onError: (_) => null);

  static Future<void> _land(ShelfItem item, Future<Object?> arrival) async {
    final copy = _copy;
    if (!_on || copy == null) return; // switched off while it was on its way
    // The user copied something since this arrived: theirs stays.
    final then = await arrival, now = await _readStamp();
    if (then != null && now != null && now != then && now != _ours) return;
    try {
      await copy(item);
    } catch (_) {
      // Expired meanwhile, or the clipboard said no: its row is still
      // there to grab by hand.
      return;
    }
    _ours = await _readStamp();
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
    _letGo();
    _copying = Future.value();
    _ours = null;
    _settings = null;
    _copy = null;
    _stamp = clipboardStamp;
    _deadline = _eagerDeadline;
    _maxBytes = defaultEagerCopyBytes;
    onCopied = null;
  }
}

typedef _Pending = ({String key, Future<Object?> stamp, Timer timer});

/// Something that changes whenever anything is copied, anywhere, compared
/// by ==; null when it can't be told. macOS: the pasteboard's changeCount,
/// read through the Objective-C runtime (no native code, and unlike
/// reading what is on it, no paste prompt on recent macOS). Windows:
/// GetClipboardSequenceNumber. Both count every copy of anything without
/// reading it. Linux has no such count: the text on the clipboard, hashed,
/// so a picture or file copied there since, or the same text copied again,
/// goes unnoticed; arrivals' deadline still bounds how late a copy lands.
Future<Object?> clipboardStamp() async {
  if (Platform.isMacOS) return _macChangeCount?.call();
  if (Platform.isWindows) return _windowsSequence?.call();
  final text = await Clipboard.getData(Clipboard.kTextPlain);
  return (text: (text?.text ?? '').hashCode);
}

/// NSPasteboard.generalPasteboard.changeCount; null without AppKit loaded
/// (a test runner).
final int Function()? _macChangeCount = () {
  try {
    final objc = DynamicLibrary.open('/usr/lib/libobjc.A.dylib');
    final named =
        objc.lookupFunction<
          Pointer<Void> Function(Pointer<Uint8>),
          Pointer<Void> Function(Pointer<Uint8>)
        >;
    final getClass = named('objc_getClass'), sel = named('sel_registerName');
    // objc_msgSend is called as the method's own C type: (id, SEL) -> id
    // for generalPasteboard, (id, SEL) -> NSInteger for changeCount.
    final sendId = objc
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>, Pointer<Void>)
        >('objc_msgSend');
    final sendLong = objc
        .lookupFunction<
          Int64 Function(Pointer<Void>, Pointer<Void>),
          int Function(Pointer<Void>, Pointer<Void>)
        >('objc_msgSend');
    final cls = getClass(_cString('NSPasteboard'));
    if (cls == nullptr) return null;
    final board = sendId(cls, sel(_cString('generalPasteboard')));
    if (board == nullptr) return null;
    final changeCount = sel(_cString('changeCount'));
    return () => sendLong(board, changeCount);
  } catch (_) {
    return null;
  }
}();

/// A NUL-terminated copy of [s], kept for good: a handful of names, once.
Pointer<Uint8> _cString(String s) {
  final bytes = utf8.encode(s);
  final p = _malloc(bytes.length + 1);
  p.asTypedList(bytes.length + 1)
    ..setAll(0, bytes)
    ..[bytes.length] = 0;
  return p;
}

final _malloc = DynamicLibrary.process()
    .lookupFunction<
      Pointer<Uint8> Function(Size),
      Pointer<Uint8> Function(int)
    >('malloc');

final int Function()? _windowsSequence = () {
  try {
    return DynamicLibrary.open('user32.dll')
        .lookupFunction<Uint32 Function(), int Function()>(
          'GetClipboardSequenceNumber',
        );
  } catch (_) {
    return null;
  }
}();
