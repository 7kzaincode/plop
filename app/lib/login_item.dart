import 'dart:io';

import 'package:flutter/services.dart';

/// Starting plop when the user logs in, so the global shortcuts are always
/// there. Desktop only.
abstract final class LoginItem {
  static const _mac = MethodChannel('plop/window');
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  static bool get supported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  static File get _linuxEntry =>
      File('${Platform.environment['HOME']}/.config/autostart/plop.desktop');

  static Future<bool> get enabled async {
    try {
      if (Platform.isMacOS) {
        return await _mac.invokeMethod<bool>('loginItem') ?? false;
      }
      if (Platform.isWindows) {
        final r = await Process.run('reg', ['query', _runKey, '/v', 'plop']);
        return r.exitCode == 0;
      }
      if (Platform.isLinux) return _linuxEntry.existsSync();
    } catch (_) {}
    return false;
  }

  /// Returns whether the change took.
  static Future<bool> set(bool on) async {
    try {
      if (Platform.isMacOS) {
        return await _mac.invokeMethod<bool>('setLoginItem', on) ?? false;
      }
      final exe = Platform.resolvedExecutable;
      if (Platform.isWindows) {
        final r = on
            ? await Process.run('reg', [
                'add', _runKey, '/v', 'plop', '/t', 'REG_SZ', //
                '/d', '"$exe"', '/f',
              ])
            : await Process.run('reg', ['delete', _runKey, '/v', 'plop', '/f']);
        return r.exitCode == 0;
      }
      if (Platform.isLinux) {
        if (on) {
          _linuxEntry
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(
              '[Desktop Entry]\nType=Application\nName=plop\nExec="$exe"\n'
              'X-GNOME-Autostart-enabled=true\n',
            );
        } else if (_linuxEntry.existsSync()) {
          _linuxEntry.deleteSync();
        }
        return true;
      }
    } catch (_) {}
    return false;
  }
}
