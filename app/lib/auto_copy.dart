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
/// clipboard once they are here (and what a phone without the app puts up
/// through the web shelf, which is this device's own to the core), when the settings panel has it switched on
/// ([Settings.autoCopy]). Off by default: anyone nearby with plop could then
/// fill the clipboard. Only arrivals count: not what was on the shelf at
/// launch, nor what a device brings in its first seconds on the network,
/// at launch, back after a while away or after this machine slept
/// ([Settling]), nor an item back with a peer that dropped off
/// ([SeenItems]). The newest arrival wins: one still on its
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
  /// is now on the clipboard; the island sets it where it shows.
  static void Function(ShelfItem item)? onCopied;

  /// Who [item] came from, as a message names them: its device, or for
  /// what a phone put up through the web shelf, which arrives as this
  /// device's own, [webSender].
  static String senderOf(ShelfItem item) =>
      _isUpload(item.key) ? webSender : item.originName;

  static String _self = '';
  static bool Function(String key) _isUpload = _never;
  static bool _never(String key) => false;

  static Settings? _settings;
  static StreamSubscription<void>? _watching;
  static Future<void> Function(ShelfItem item)? _copy;
  static Future<Object?> Function() _stamp = clipboardStamp;
  static Duration Function(int bytes) _deadline = _eagerDeadline;
  static var _maxBytes = defaultEagerCopyBytes;

  /// Every item from another device seen so far, copied or not.
  static final _seen = SeenItems();
  static var _settling = Settling(grace: Notify.grace, settle: Notify.settle);

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
    isUpload: node.web.isUpload,
    settings: settings,
    maxBytes: node.engine.eagerCopyBytes,
    deadline: node.engine.eagerDeadlineFor,
    copy: (item) => copyItem(node, item, orFile: false),
  );

  /// [watch] with the node taken apart: [changes] fires whenever [items],
  /// the shelf, or [peers], the ids of the other devices, may have changed;
  /// [self] is this device's id, [isUpload] tells which of its own items a
  /// phone put up through the web shelf, [copy] puts an item on the clipboard,
  /// [maxBytes] is the eager-copy size and [deadline] the time an eager
  /// copy of a size gets. [stamp] stands in for [clipboardStamp] and
  /// [clock] for the wall clock, which shows when the machine slept.
  @visibleForTesting
  static void watchItems(
    Stream<void> changes,
    Iterable<ShelfItem> Function() items,
    Iterable<String> Function() peers, {
    required String self,
    bool Function(String key)? isUpload,
    required Settings settings,
    required Future<void> Function(ShelfItem item) copy,
    int maxBytes = defaultEagerCopyBytes,
    Duration Function(int bytes)? deadline,
    Future<Object?> Function()? stamp,
    DateTime Function()? clock,
  }) {
    if (!isDesktop) return;
    _settings = settings;
    _self = self;
    _isUpload = isUpload ?? _never;
    _copy = copy;
    _maxBytes = maxBytes;
    _deadline = deadline ?? _eagerDeadline;
    _stamp = stamp ?? clipboardStamp;
    _settling.clear();
    _settling = Settling(grace: Notify.grace, settle: Notify.settle, now: clock)
      ..start();
    void check() {
      _settling.check(); // slept since? then this is old news
      final here = peers().toList();
      _settling.present(here);
      here.forEach(_settling.hear);
      _arrived(items().where((i) => i.originId != self || _isUpload(i.key)));
    }

    check();
    _watching?.cancel();
    _watching = changes.listen((_) => check());
  }

  static Duration _eagerDeadline(int bytes) =>
      defaultEagerDeadline +
      Duration(milliseconds: bytes * 1000 ~/ (256 << 10));

  static bool get _on => _settings?.autoCopy ?? false;

  /// Older than this when it got here (its sender says how old, from
  /// plop's protocol `ageMs`): not an arrival to put on the clipboard, but
  /// something that was waiting while this device was asleep or away. A
  /// sender too old to say gets the [Settling] rules alone.
  static const fresh = Duration(seconds: 30);

  /// Text, or a picture this OS's clipboard takes as one ([copiesAsImage]:
  /// none on Linux, no HEIC or WebP on Windows, never SVG), small enough to
  /// have been copied here on sight. A picture the clipboard can't take
  /// would go on it as a file, and files never do.
  static bool _wanted(ShelfItem item) =>
      (item.kind == ItemKind.text || copiesAsImage(item)) &&
      item.size <= _maxBytes;

  /// The shelf's items from other devices, and the web shelf's uploads, as
  /// they are now. An upload is known as one a moment after the store has
  /// it as this device's own (WebHost.changes); it is new then.
  static void _arrived(Iterable<ShelfItem> remote) {
    final items = remote.toList();
    final here = <String>{};
    ShelfItem? newest;
    for (final item in items) {
      here.add(item.key);
      // An upload is never something a device already had.
      final upload = item.originId == _self;
      if (!upload) _settling.hear(item.originId);
      if (!_seen.add(item)) continue;
      // Switched off (switching on later does not reach back), a device
      // that is only turning up, something already old when it got here
      // (put up while this machine slept, say), or nothing for the
      // clipboard.
      if (!_on ||
          (!upload && _settling.isQuiet(item.originId)) ||
          (item.ageAtArrival ?? Duration.zero) > fresh ||
          !_wanted(item)) {
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
    if (!ready.isReady) {
      // Its copy just started: from now, its own deadline.
      if (!pending.started && ready.progress != null) {
        pending.timer.cancel();
        _pending = (
          key: pending.key,
          stamp: pending.stamp,
          started: true,
          timer: _expire(pending.key, _deadline(ready.size)),
        );
      }
      return;
    }
    _letGo();
    // An [onCopied] that throws must not stop every copy after it.
    _copying = _copying
        .then((_) => _land(ready, pending.stamp))
        .catchError((_) {});
  }

  /// [item] is the one to copy once it is here, so long as that is within
  /// its eager-copy deadline of the copy starting. It may wait its turn
  /// first (four copies at a time, two per device), so until it starts it
  /// gets [_queued] times as long.
  static void _wait(ShelfItem item) {
    _letGo();
    _pending = (
      key: item.key,
      stamp: _readStamp(),
      started: false,
      timer: _expire(item.key, _deadline(item.size) * _queued),
    );
  }

  static const _queued = 4;

  static Timer _expire(String key, Duration after) => Timer(after, () {
    if (_pending?.key == key) _pending = null;
  });

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
    // With the island, it marks the item's row; without, its arrival's
    // notification says so, or a line of its own when there is none.
    final hook = onCopied;
    if (hook != null) {
      hook(item);
    } else if (!Notify.copied(item)) {
      Notify.say('copied ${messageName(item)} from ${senderOf(item)}');
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
    _self = '';
    _isUpload = _never;
    _copy = null;
    _stamp = clipboardStamp;
    _deadline = _eagerDeadline;
    _maxBytes = defaultEagerCopyBytes;
    onCopied = null;
  }
}

/// How a message names whoever put an item up through the web shelf: a
/// phone without the app, as a rule.
const webSender = 'a phone (web)';

typedef _Pending = ({
  String key,
  Future<Object?> stamp,
  bool started,
  Timer timer,
});

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
    // Every Mac app has the Objective-C runtime loaded already.
    final objc = DynamicLibrary.process();
    // lookupFunction must be called directly, each time: stored as a value
    // it throws, which would leave the stamp unknown and the user's own
    // copy unprotected.
    final getClass = objc
        .lookupFunction<
          Pointer<Void> Function(Pointer<Uint8>),
          Pointer<Void> Function(Pointer<Uint8>)
        >('objc_getClass');
    final sel = objc
        .lookupFunction<
          Pointer<Void> Function(Pointer<Uint8>),
          Pointer<Void> Function(Pointer<Uint8>)
        >('sel_registerName');
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
