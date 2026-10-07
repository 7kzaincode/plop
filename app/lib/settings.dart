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

  /// Backed by [file], starting empty; for tests that need a real write.
  Settings.at(File file) : _file = file, _data = {};

  final File? _file;
  final Map<String, Object?> _data;

  static Future<Settings> load() async {
    final dir = await getApplicationSupportDirectory();
    return loadFrom(File('${dir.path}${Platform.pathSeparator}settings.json'));
  }

  /// What [file] holds, backed by it from now on; [load] with the file
  /// named, so tests can read back what was written.
  static Future<Settings> loadFrom(File file) async {
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
    _save().ignore(); // the picker has nowhere to say it failed
  }

  /// Showing arrivals and shortcut results while plop is in the background:
  /// the island on macOS, OS notifications elsewhere (lib/notify.dart). On
  /// unless switched off.
  bool get notifications => _data['notifications'] != false;

  set notifications(bool on) {
    _data['notifications'] = on;
    _save().ignore(); // the toggle has nowhere to say it failed
  }

  /// Text and pictures from other devices go straight onto the clipboard as
  /// they arrive (lib/auto_copy.dart). Off unless switched on: with it on,
  /// anyone nearby with plop can put whatever they like on the clipboard,
  /// to be pasted without a look.
  bool get autoCopy => _data['autoCopy'] == true;

  set autoCopy(bool on) {
    _data['autoCopy'] = on;
    _save().ignore(); // the toggle has nowhere to say it failed
  }

  /// Whether plop has said, once, that closing the window keeps it running
  /// in the tray (lib/notify.dart).
  bool get trayNoticeShown => _data['trayNoticeShown'] == true;

  set trayNoticeShown(bool shown) {
    _data['trayNoticeShown'] = shown;
    _save().ignore(); // at worst it is said once more
  }

  /// The port the web shelf was first served on, asked for first on every
  /// launch so its address on a phone's home screen keeps working; null
  /// before the first launch, and for anything that is not a port (a file
  /// edited by hand, say), which binding would refuse with an error.
  int? get webPort => switch (_data['webPort']) {
    final int p when p >= 1 && p <= 65535 => p,
    _ => null,
  };

  set webPort(int? port) {
    _data['webPort'] = port;
    _save().ignore();
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

  /// Completes once the file is written, or fails if it could not be: the
  /// new binding still works until plop quits, and the panel says so.
  Future<void> setHotkey(String name, HotKey? k) {
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
    return _save();
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(_data));
  }
}
