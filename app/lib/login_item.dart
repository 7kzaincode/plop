import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the login item is after a change. [needsApproval] is macOS holding
/// a registered item until the user switches it on in System Settings ›
/// General › Login Items, which the change opens.
enum LoginState { on, off, needsApproval }

/// Starting plop when the user logs in, so the global shortcuts are always
/// there. Desktop only.
abstract final class LoginItem {
  static const _mac = MethodChannel('plop/window');
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  static bool get supported =>
      Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS && macHasLoginItems(Platform.operatingSystemVersion);

  /// Whether a Mac whose version reads [version] (as
  /// Platform.operatingSystemVersion gives it, "Version 13.4 (Build
  /// 22F66)") has SMAppService, which open at login needs: macOS 13 and
  /// later. On 12 the switch could only ever say "couldn't change that
  /// here", which reads like a bug; it isn't offered there. A version that
  /// can't be read counts as new enough.
  @visibleForTesting
  static bool macHasLoginItems(String version) {
    final major = RegExp(r'\d+').firstMatch(version)?.group(0);
    return (int.tryParse(major ?? '') ?? 13) >= 13;
  }

  static String get _home => Platform.environment['HOME'] ?? '';
  static String get _xdgConfig =>
      Platform.environment['XDG_CONFIG_HOME'] ?? '$_home/.config';
  static String get _xdgData =>
      Platform.environment['XDG_DATA_HOME'] ?? '$_home/.local/share';

  static File get _linuxEntry => File('$_xdgConfig/autostart/plop.desktop');

  /// Named after the GTK application id (linux/CMakeLists.txt): that is how
  /// GNOME matches the running window to its launcher entry and icon.
  static File get _linuxLauncher =>
      File('$_xdgData/applications/dev.plop.plop.desktop');

  /// A desktop entry for this build. Icon= takes an absolute path, so the
  /// plop.png the tarball puts next to the executable needs no icon theme.
  /// StartupWMClass is GTK's WM_CLASS on X11, which the runner sets to the
  /// application id with g_set_prgname; on Wayland the id does the matching.
  static String _linuxDesktopEntry() {
    final exe = Platform.resolvedExecutable;
    return '[Desktop Entry]\nType=Application\nName=plop\nExec="$exe"\n'
        'Icon=${File(exe).parent.path}/plop.png\nStartupWMClass=dev.plop.plop\n'
        'Categories=Utility;\n';
  }

  /// Linux: the tarball has no installer, so the first launch registers plop
  /// with the desktop (launcher search, dock icon, pinning). Release builds
  /// only, so `flutter run` never points the launcher at a build directory.
  static void installLauncher() {
    if (!Platform.isLinux || !kReleaseMode) return;
    try {
      final entry = _linuxDesktopEntry();
      final f = _linuxLauncher;
      if (f.existsSync() && f.readAsStringSync() == entry) return;
      f
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(entry);
    } catch (_) {}
  }

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

  /// Returns what the item is now, which is the old state when the change
  /// did not take.
  static Future<LoginState> set(bool on) async {
    final asked = on ? LoginState.on : LoginState.off;
    final kept = on ? LoginState.off : LoginState.on;
    try {
      if (Platform.isMacOS) {
        return switch (await _mac.invokeMethod<String>('setLoginItem', on)) {
          'on' => LoginState.on,
          'needsApproval' => LoginState.needsApproval,
          _ => LoginState.off,
        };
      }
      final exe = Platform.resolvedExecutable;
      if (Platform.isWindows) {
        final r = on
            ? await Process.run('reg', [
                'add', _runKey, '/v', 'plop', '/t', 'REG_SZ', //
                '/d', '"$exe"', '/f',
              ])
            : await Process.run('reg', ['delete', _runKey, '/v', 'plop', '/f']);
        return r.exitCode == 0 ? asked : kept;
      }
      if (Platform.isLinux) {
        if (on) {
          _linuxEntry
            ..parent.createSync(recursive: true)
            ..writeAsStringSync(
              '${_linuxDesktopEntry()}X-GNOME-Autostart-enabled=true\n',
            );
        } else if (_linuxEntry.existsSync()) {
          _linuxEntry.deleteSync();
        }
        return asked;
      }
    } catch (_) {}
    return kept;
  }
}
