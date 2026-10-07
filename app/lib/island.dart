import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:plop_core/plop_core.dart';

import 'grab.dart';
import 'notify.dart';
import 'shelf_screen.dart' show formatSize;
import 'type_icons.dart';
import 'window.dart';

/// The island on macOS: a black pill that drops out of the notch (from the
/// top edge on a screen without one) when something arrives from another
/// device while plop is not in front, with copy and save on it and the file
/// draggable out of it into any app; it also says what a global shortcut
/// did. It takes the place of the Dock bounce and the notification there,
/// so an arrival is one calm thing instead of three, and it never takes
/// the keyboard from whatever the user is typing in.
///
/// This side decides what to show and does the copying and saving, with the
/// same code as the shelf's rows; macos/Runner/Island.swift draws it.
/// [Notify] calls in, under the same rules as its notifications: only while
/// the window is not focused, and not with them switched off.
abstract final class Island {
  static const _channel = MethodChannel('plop/island');

  /// Arrivals from one device this close together share one island; less
  /// than [Notify.burst], since the island is meant to be quick.
  static const burst = Duration(milliseconds: 700);

  static PlopNode? _node;
  static String Function()? _hint;
  static final _icons = <FileCategory, Uint8List>{};

  /// What the island shows now (sent again when the shelf changes under
  /// it), what each row's line says after a click, and where saves landed.
  static String _sender = '';
  static List<ShelfItem> _shown = [];
  static final _marks = <String, (String, bool)>{};
  static final _saved = <String, String>{};

  /// Keys of shown items already copied here, to see which just landed.
  static var _ready = <String>{};

  static bool get supported => Platform.isMacOS;

  /// Whether arrivals and shortcut results go to the island.
  static bool get active => _node != null || _debugActive;
  static var _debugActive = false;

  /// Tests: the island as if [init] had run, with no node behind it.
  @visibleForTesting
  static void debugActivate() => _debugActive = true;

  /// Tests: back to never having been set up.
  @visibleForTesting
  static void reset() {
    _debugActive = false;
    _node = null;
    _shown = [];
    _marks.clear();
    _saved.clear();
    _autoCopied.clear();
  }

  /// Call after runApp on macOS. [hint] names the shortcut that grabs the
  /// newest arrival, for the copy button's tooltip.
  static void init(PlopNode node, {String Function()? hint}) {
    if (!supported) return;
    _node = node;
    _hint = hint;
    _channel.setMethodCallHandler(_handle);
    node.changes.listen((_) => _sync());
    // The shelf itself is in front now, and says it all.
    AppLifecycleListener(onResume: hide);
  }

  /// [items] just arrived from [sender]. Joins what is showing when that is
  /// from the same device.
  static Future<void> arrived(String sender, List<ShelfItem> items) async {
    if (!active || items.isEmpty) return;
    if (_shown.isNotEmpty && _sender == sender) {
      final keys = {for (final i in _shown) i.key};
      _shown = [..._shown, ...items.where((i) => !keys.contains(i.key))];
    } else {
      _shown = [...items];
      _marks.clear();
    }
    _sender = sender;
    await _send();
  }

  /// A shortcut's result: "plopped clipboard", "nothing to paste".
  static void say(String text, {bool ok = true}) {
    if (!active) return;
    _seq++; // whatever was on its way is out of date now
    _shown = [];
    _channel.invokeMethod<void>('say', {'text': text, 'ok': ok}).ignore();
  }

  /// [item] went onto the clipboard by itself (auto-copy): the island says
  /// so on its row. A small text is often copied before its arrival is
  /// shown, so the row says so when it comes; if it never does (the window
  /// was focused, say), a line of its own says it.
  static void copied(ShelfItem item) {
    if (!active) return;
    // The clipboard holds one thing: an earlier row's line goes back to
    // what it said.
    for (final key in _autoCopied.toList()) {
      _autoCopied.remove(key);
      if (_marks[key]?.$1 == _copiedLine) _marks.remove(key);
      if (_shown.any((i) => i.key == key)) _send().ignore();
    }
    _autoCopied.add(item.key);
    if (_shown.any((i) => i.key == item.key)) {
      _mark(item.key, _copiedLine, settled: false).ignore();
      return;
    }
    Timer(burst * 2, () {
      if (_shown.any((i) => i.key == item.key)) return;
      if (Notify.islandWanted) {
        say('copied ${_title(item)} from ${item.originName}');
      }
    });
  }

  static const _copiedLine = '✓ copied automatically';

  /// Keys auto-copy put on the clipboard, for their rows' line.
  static final _autoCopied = <String>{};

  static void hide() {
    if (!active) return;
    _seq++;
    _shown = [];
    _channel.invokeMethod<void>('hide').ignore();
  }

  /// Counts what was sent, so a send still describing its items when a
  /// newer show, say or hide went out is dropped rather than shown over it.
  static var _seq = 0;

  static Future<void> _send() async {
    final seq = ++_seq;
    final sender = _sender, shown = _shown;
    _ready = {
      for (final i in shown)
        if (i.isReady) i.key,
    };
    final payload = [for (final i in shown.take(8)) await _describe(i)];
    if (seq != _seq) return;
    await _channel
        .invokeMethod<void>('show', {
          'sender': sender,
          'items': payload,
          'count': shown.length,
          'hint': ?_hint?.call(),
        })
        .catchError((_) {});
  }

  /// Text shows as "text" and how long it is, its first line only under the
  /// pointer: a copied password or code should not sit on a shared screen.
  @visibleForTesting
  static Future<Map<String, Object>> describe(ShelfItem i) => _describe(i);

  static Future<Map<String, Object>> _describe(ShelfItem i) async {
    final category = categoryOf(i);
    final icon = _icons[category] ??= await typeIconPng(category);
    final path = i.isReady ? i.path : null;
    final text = i.kind == ItemKind.text && path != null && i.size <= 64 * 1024
        ? await File(path)
              .readAsString()
              .then<String?>((t) => t, onError: (_) => null)
        : null;
    final mark =
        _marks[i.key] ??
        (_autoCopied.contains(i.key) ? (_copiedLine, false) : null);
    return {
      'key': i.key,
      'title': _title(i),
      if (i.kind == ItemKind.text) 'reveal': i.name,
      'meta': switch (i.kind) {
        ItemKind.text when text != null =>
          '${text.characters.length} character${text.characters.length == 1 ? '' : 's'}',
        ItemKind.text => '',
        ItemKind.folder => 'folder · ${formatSize(i.size)}',
        ItemKind.file => formatSize(i.size),
      },
      'icon': icon,
      if (path != null && isCopyableImage(i)) 'thumb': path,
      if (path != null && i.kind == ItemKind.file) 'dragFile': path,
      'dragText': ?text,
      // Copy then save on every row, so the buttons line up down a list.
      'actions': [
        for (final a in GrabAction.values)
          if (a != GrabAction.share && actionsFor(i).contains(a)) a.name,
      ],
      if (mark != null) 'mark': mark.$1,
      if (mark != null) 'error': mark.$2,
    };
  }

  static String _title(ShelfItem i) =>
      i.kind == ItemKind.text ? 'text' : i.name;

  @visibleForTesting
  static Future<void> debugMark(
    String key,
    String text, {
    bool settled = true,
  }) => _mark(key, text, settled: settled);

  /// Puts [text] on [key]'s row. A slow save can finish after the island
  /// tucked away, and macOS has no notification to fall back on now, so
  /// the result then shows on its own; "copying…" and the like don't.
  static Future<void> _mark(
    String key,
    String text, {
    bool error = false,
    bool settled = true,
  }) async {
    _marks[key] = (text, error);
    final shown = await _channel
        .invokeMethod<bool>('mark', {'key': key, 'mark': text, 'error': error})
        .catchError((_) => false);
    if (shown != true && settled) {
      say(
        text.replaceFirst('✓ ', '').replaceFirst(' · click to show', ''),
        ok: !error,
      );
    }
  }

  /// A row's thumbnail and drag wait for its copy to land; an item that
  /// left the shelf leaves the island.
  static void _sync() {
    final node = _node;
    if (node == null) return;
    _autoCopied.removeWhere((k) => node.store[k] == null);
    _saved.removeWhere((k, _) => node.store[k] == null);
    _marks.removeWhere((k, _) => node.store[k] == null);
    if (_shown.isEmpty) return;
    final gone = [
      for (final i in _shown)
        if (node.store[i.key] == null) i.key,
    ];
    for (final key in gone) {
      _channel.invokeMethod<void>('drop', {'key': key}).ignore();
    }
    _shown = [for (final i in _shown) ?node.store[i.key]];
    final ready = {
      for (final i in _shown)
        if (i.isReady) i.key,
    };
    // Landed since: its thumbnail and drag can come now.
    if (_shown.isNotEmpty && ready.difference(_ready).isNotEmpty) {
      _send().ignore();
    }
    _ready = ready;
  }

  static Future<void> _handle(MethodCall call) async {
    final node = _node;
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
    if (call.method == 'hidden') {
      _seq++;
      _shown = [];
      return;
    }
    if (call.method != 'action' || node == null) return;
    final key = args['key'] as String?;
    final item = key == null ? null : node.store[key];
    if (item == null) return;
    switch (args['action']) {
      case 'copy':
        _mark(
          item.key,
          item.isReady ? 'copying…' : 'getting it…',
          settled: false,
        ).ignore();
        try {
          final said = await copyItem(node, item);
          await _mark(item.key, '✓ ${said.split(' · ').first}');
        } catch (e) {
          await _mark(item.key, friendlyError(e), error: true);
        }
      case 'save':
        _mark(
          item.key,
          item.isReady ? 'saving…' : 'getting it…',
          settled: false,
        ).ignore();
        try {
          final path = await saveItem(node, item);
          _saved[item.key] = path;
          await _mark(
            item.key,
            '✓ saved to ${savedWhere(path)} · click to show',
          );
        } catch (e) {
          await _mark(item.key, friendlyError(e), error: true);
        }
      case 'open':
        if (_saved[item.key] case final path?) {
          await reveal(path);
        } else {
          AppWindow.show();
        }
    }
  }
}
