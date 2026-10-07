import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/widgets.dart'
    show AppLifecycleListener, visibleForTesting;
import 'package:plop_core/plop_core.dart';
import 'package:tray_manager/tray_manager.dart';

import 'window.dart';

/// plop's icon in the menu bar (macOS) or the notification area (Windows,
/// Linux), which is how it lives on once the window is closed, like Steam
/// or Medal: "open plop" brings the window back, a dim line says which
/// device this is and how many are nearby, "quit plop" ends it. On Windows
/// a left click opens the window and a right click the menu; on macOS, as
/// with other menu bar extras, a click opens the menu; on Linux the panel
/// opens it on any click (AppIndicator never passes clicks to the app).
///
/// tray_manager 0.5 is the desktop-only, method-channel version: nothing of
/// it is built into the Android or iOS app (0.7 compiled a whole native
/// library for both). Its icon belongs to plop's own window on Windows, so
/// the window is hidden, never destroyed, while plop runs.
///
/// Closing the window on Windows and Linux reaches Dart first, as Flutter's
/// request to exit the app (the window is the process's only top-level
/// one); with the icon up it is answered with a hide (see
/// [onExitRequested]). The runners hide on a close that gets through to the
/// window itself too, once told the icon is up ([AppWindow.hideOnClose]).
/// macOS keeps running after a close on its own.
abstract final class Tray {
  static Future<void>? _init;
  static Menu? _menu;
  static MenuItem? _status;
  static bool _up = false;
  static bool _quitting = false;

  /// Tests: stands in for an icon being up.
  @visibleForTesting
  static bool? debugActive;

  static bool get supported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// Whether the icon is up, so the window may close into it.
  static bool get active => debugActive ?? _up;

  /// Call after runApp. Never throws: without a tray (a Linux desktop with
  /// no StatusNotifier host, a plugin that did not load) plop behaves as
  /// before and the window's close button quits.
  static Future<void> init(PlopNode node) =>
      _init ??= supported ? _start(node) : Future.value();

  static Future<void> _start(PlopNode node) async {
    var shown = false;
    try {
      if (Platform.isLinux && !await _linuxHasTrayHost()) return;
      await trayManager.setIcon(
        Platform.isWindows ? await _windowsIcon() : 'assets/brand/tray.png',
        // macOS: alpha only, so the mark follows a light or dark menu bar,
        // drawn at 18 pt from the 36 px image. Ignored elsewhere.
        isTemplate: true,
        iconSize: 18,
      );
      shown = true;
      // Linux has no tooltip (the plugin answers "not implemented").
      if (!Platform.isLinux) await trayManager.setToolTip('plop');
      final status = MenuItem(label: _line(node), disabled: true);
      final menu = Menu(
        items: [
          MenuItem(key: 'open', label: 'open plop'),
          MenuItem.separator(),
          status,
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'quit plop'),
        ],
      );
      await trayManager.setContextMenu(menu);
      trayManager.addListener(_Clicks(node));
      _menu = menu;
      _status = status;
      _up = true;
      node.changes.listen((_) => _update(node));
      AppLifecycleListener(onExitRequested: onExitRequested);
      await AppWindow.hideOnClose(true);
    } catch (_) {
      // The plugin is missing or failed part way: no icon, and closing the
      // window quits, as before there was one.
      _up = false;
      if (shown) trayManager.destroy().catchError((_) {}).ignore();
    }
  }

  /// Flutter asking whether the app may exit: the window's close button on
  /// Windows and Linux (the embedders ask before the runner sees the close,
  /// and quit on "exit"), ⌘Q on macOS, and the runner's own quit on Windows.
  /// A close with the icon up hides the window instead; everything else
  /// goes through. Closing the window on macOS never asks.
  @visibleForTesting
  static Future<AppExitResponse> onExitRequested() async {
    if (Platform.isMacOS || _quitting || !active) return AppExitResponse.exit;
    AppWindow.hide();
    return AppExitResponse.cancel;
  }

  /// Ends plop: the icon goes, the peers get their goodbye (bounded; they
  /// would notice anyway) and the runner quits.
  static Future<void> quit(PlopNode node) async {
    if (_quitting) return;
    _quitting = true;
    if (_up) await trayManager.destroy().catchError((_) {});
    await node.stop().timeout(const Duration(seconds: 2)).catchError((_) {});
    await AppWindow.quit();
  }

  /// "Zain's Mac · 2 nearby", counting as the top bar does.
  static String _line(PlopNode node) {
    final n = node.peers.length;
    return '${node.store.nodeName} · ${n == 0 ? 'just you' : '$n nearby'}';
  }

  /// The menu is sent whole; only when the line changes, not on every
  /// download tick. The same items keep their ids, so a click on a menu
  /// that was open across the change still finds its item.
  static void _update(PlopNode node) {
    final status = _status, menu = _menu;
    final line = _line(node);
    if (status == null || menu == null || status.label == line) return;
    status.label = line;
    trayManager.setContextMenu(menu).catchError((_) {});
  }

  /// Opens the icon's menu where the pointer is.
  static void _popUp() {
    trayManager
        .popUpContextMenu(
          // Windows only closes a tray menu on a click elsewhere if its
          // owner, plop's window (hidden or not), was put in front first;
          // this flag does that. Ignored elsewhere.
          // ignore: deprecated_member_use
          bringAppToFront: Platform.isWindows,
        )
        .catchError((_) {});
  }

  /// Whether a panel on this desktop shows StatusNotifier icons: KDE and
  /// most others do, GNOME only with the AppIndicator extension (Ubuntu
  /// ships it switched on). Without one the icon would be invisible and a
  /// window closed into it would have no way back, so then closing quits
  /// as before. gdbus comes with GLib.
  static Future<bool> _linuxHasTrayHost() async {
    try {
      final r = await Process.run('gdbus', [
        'call', '--session', //
        '--dest', 'org.kde.StatusNotifierWatcher',
        '--object-path', '/StatusNotifierWatcher',
        '--method', 'org.freedesktop.DBus.Properties.Get',
        'org.kde.StatusNotifierWatcher', 'IsStatusNotifierHostRegistered',
      ]).timeout(const Duration(seconds: 3));
      return r.exitCode == 0 && (r.stdout as String).contains('true');
    } catch (_) {
      return false;
    }
  }

  /// Windows draws tray icons as they are, so the light theme's light
  /// taskbar gets the black mark (tool/make_icon.py). Read once, at launch.
  /// The plugin loads an .ico from the app's assets at the small icon size.
  static Future<String> _windowsIcon() async {
    try {
      final r = await Process.run('reg', [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
        '/v',
        'SystemUsesLightTheme',
      ]);
      if (r.exitCode == 0 && RegExp(r'0x1\b').hasMatch(r.stdout as String)) {
        return 'assets/brand/tray_light.ico';
      }
    } catch (_) {}
    return 'assets/brand/tray.ico';
  }
}

/// Clicks on the icon and its menu. Linux never reports a click on the
/// icon itself: the panel opens the menu.
class _Clicks with TrayListener {
  _Clicks(this.node);
  final PlopNode node;

  /// A left click (Windows reports it on release): the window on Windows,
  /// the menu in the macOS menu bar.
  @override
  void onTrayIconMouseDown() {
    if (Platform.isWindows) {
      AppWindow.show();
    } else {
      Tray._popUp();
    }
  }

  @override
  void onTrayIconRightMouseDown() => Tray._popUp();

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'open':
        AppWindow.show();
      case 'quit':
        Tray.quit(node).ignore();
    }
  }
}
