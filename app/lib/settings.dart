import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:plop_core/plop_core.dart';

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

  /// Completes once the file is written, or fails if it could not be: the
  /// lifetime still holds until plop quits, and the shelf says so.
  Future<void> setTtl(Duration d) {
    _data['ttlMs'] = d.inMilliseconds;
    return _save();
  }

  /// Showing arrivals and shortcut results while plop is in the background:
  /// the island on macOS, Windows and Linux under X11 (lib/island.dart), OS
  /// notifications on Wayland (lib/notify.dart). On unless switched off.
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

  /// Asking GitHub for a newer plop twice a day (lib/updates.dart), the
  /// only thing plop asks of the internet. On unless switched off.
  bool get checkUpdates => _data['checkUpdates'] != false;

  set checkUpdates(bool on) {
    _data['checkUpdates'] = on;
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

/// This device's private mode (lib/src/private_mode.dart in the core): its
/// long-term key, its circle and the switch, in `private[-suffix].json`
/// beside settings.json, apart from it so only this user can read it
/// ([writeSecret]). [suffix] is PLOP_INSTANCE's, so a dev build beside the
/// installed plop is another device, as it is on the network.
Future<PrivateMode> loadPrivateMode({String suffix = ''}) async {
  final dir = await getApplicationSupportDirectory();
  final file = File('${dir.path}${Platform.pathSeparator}private$suffix.json');
  Map<String, Object?>? json;
  try {
    json = (jsonDecode(await file.readAsString()) as Map).cast();
  } catch (_) {
    // None yet, or unreadable: a new key.
  }
  return PrivateMode.load(json, save: (j) => writeSecret(file, jsonEncode(j)));
}

/// Writes [text] to [file] so that only this user can read it: on macOS
/// and Linux the file is made 0600 while still empty, before the key goes
/// in, and then moved over the old one. Windows keeps app data per user
/// already, and Android and iOS keep it in the app's own sandbox, where
/// there is no chmod to run.
Future<void> writeSecret(File file, String text) async {
  await file.parent.create(recursive: true);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString('');
  if (Platform.isMacOS || Platform.isLinux) {
    await Process.run('chmod', ['600', tmp.path]);
  }
  await tmp.writeAsString(text, flush: true);
  await tmp.rename(file.path);
}
