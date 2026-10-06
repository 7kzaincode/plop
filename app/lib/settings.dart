import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:path_provider/path_provider.dart';

/// Lifetimes offered in the picker.
const ttlChoices = [
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(minutes: 2),
  Duration(minutes: 5),
  Duration(minutes: 15),
  Duration(hours: 1),
];

String formatTtl(Duration d) => d.inHours > 0
    ? '${d.inHours}h'
    : d.inMinutes > 0
    ? '${d.inMinutes}m'
    : '${d.inSeconds}s';

/// The few things worth remembering between launches, in a JSON file.
class Settings {
  Settings._(this._file, this._data);

  /// Kept only in memory, for tests.
  Settings.inMemory() : _file = null, _data = {};

  final File? _file;
  final Map<String, Object?> _data;

  static Future<Settings> load() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}settings.json');
    var data = <String, Object?>{};
    try {
      data = (jsonDecode(await file.readAsString()) as Map).cast();
    } catch (_) {
      // Missing or unreadable: start fresh.
    }
    return Settings._(file, data);
  }

  Duration get ttl {
    final ms = _data['ttlMs'];
    return ms is int ? Duration(milliseconds: ms) : const Duration(minutes: 2);
  }

  set ttl(Duration d) {
    _data['ttlMs'] = d.inMilliseconds;
    _save();
  }

  /// A custom global shortcut, or null for the default.
  HotKey? hotkey(String name) {
    final j = _data['hotkey.$name'];
    if (j is! Map) return null;
    try {
      return HotKey(
        key: PhysicalKeyboardKey(j['key'] as int),
        modifiers: [
          for (final m in j['mods'] as List)
            HotKeyModifier.values.byName(m as String),
        ],
      );
    } catch (_) {
      return null; // written by another version; fall back to the default
    }
  }

  void setHotkey(String name, HotKey? k) {
    if (k == null) {
      _data.remove('hotkey.$name');
    } else {
      _data['hotkey.$name'] = {
        'key': k.physicalKey.usbHidUsage,
        'mods': [
          for (final m in k.modifiers ?? const <HotKeyModifier>[]) m.name,
        ],
      };
    }
    _save();
  }

  void _save() {
    final file = _file;
    if (file == null) return;
    file.parent
        .create(recursive: true)
        .then((_) => file.writeAsString(jsonEncode(_data)))
        .catchError((_) => file);
  }
}
