import 'dart:io';
import 'dart:ui' show AppExitResponse, Size;

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
/// opens it on any click (clicks never reach the app there).
///
/// Closing the window on Windows and Linux reaches Dart first, as Flutter's
/// request to exit the app; with the icon up it is answered with a hide
/// (see [onExitRequested]). The runners hide on a close that gets through
/// to the window itself too, once told the icon is up
/// ([AppWindow.hideOnClose]). macOS keeps running after a close on its own.
abstract final class Tray {
  static TrayIcon? _icon;
  static MenuItem? _status;
  static String _statusText = '';
  static bool _quitting = false;

  /// Tests: stands in for an icon being up.
  @visibleForTesting
  static bool? debugActive;

  /// nativeapi wrappers free their handle when garbage collected, and that
  /// removes the icon or the menu; everything shown is kept here for good.
  static final _keep = <Object>[];

  static bool get supported =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  /// Whether the icon is up, so the window may close into it.
  static bool get active => debugActive ?? _icon != null;

  /// Call after runApp. Never throws: without a tray (a Linux desktop with
  /// no StatusNotifier host, Windows without its shell, a plugin that did
  /// not load) plop behaves as before and the window's close button quits.
  static Future<void> init(PlopNode node) async {
    if (!supported || _icon != null) return;
    try {
      if (!TrayManager.instance.isSupported()) return;
      if (Platform.isLinux && !await _linuxHasTrayHost()) return;
      final image = ImageAsset.fromAsset(
        Platform.isWindows ? await _windowsIcon() : 'assets/brand/tray.png',
      );
      final icon = TrayIcon.create();
      final menu = Menu.create();
      final open = _item('open plop');
      final status = _item(_line(node));
      final quit = _item('quit plop');
      if (image == null ||
          icon == null ||
          menu == null ||
          open == null ||
          status == null ||
          quit == null) {
        return; // the finalizers free what was made
      }
      _keep.addAll([image, menu, open, status, quit]);
      open.addListener((e) {
        if (e is MenuItemClickedEvent) AppWindow.show();
      });
      status.isEnabled = false;
      quit.addListener((e) {
        if (e is MenuItemClickedEvent) Tray.quit(node);
      });
      menu
        ..addItem(open)
        ..addSeparator()
        ..addItem(status)
        ..addSeparator()
        ..addItem(quit);
      icon
        ..icon = image
        // macOS: alpha only, so the mark follows a light or dark menu bar.
        ..isIconTemplate = true
        ..iconSize = const Size(18, 18)
        ..setTooltip('plop')
        ..setContextMenu(menu)
        // Linux exposes the menu to the panel only for this trigger.
        ..setContextMenuTrigger(
          Platform.isWindows
              ? ContextMenuTrigger.rightClicked
              : ContextMenuTrigger.clicked,
        );
      // nativeapi only wires up clicks once there is a listener.
      icon.addListener((event) {
        switch (event) {
          case TrayIconClickedEvent():
            if (Platform.isWindows) AppWindow.show();
          case TrayIconRightClickedEvent():
            if (Platform.isMacOS) icon.openContextMenu();
          case TrayIconDoubleClickedEvent():
            AppWindow.show();
        }
      });
      if (!icon.setVisible(true)) return; // no notification area to show in
      _icon = icon;
      _status = status;
      _statusText = _line(node);
      node.changes.listen((_) => _update(node));
      AppLifecycleListener(onExitRequested: onExitRequested);
      await AppWindow.hideOnClose(true);
    } catch (_) {
      // The plugin's library is missing or failed: no icon, and closing
      // the window quits, as before there was one.
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

  /// Ends plop: the peers get their goodbye (bounded; they would notice
  /// anyway) and the runner quits.
  static Future<void> quit(PlopNode node) async {
    _quitting = true;
    _icon?.setVisible(false);
    await node.stop().timeout(const Duration(seconds: 2)).catchError((_) {});
    await AppWindow.quit();
  }

  static MenuItem? _item(String label) =>
      MenuItem.createWithLabelAndType(label, MenuItemType.normal);

  /// "Zain's Mac · 2 nearby", counting as the top bar does.
  static String _line(PlopNode node) {
    final n = node.peers.length;
    return '${node.store.nodeName} · ${n == 0 ? 'just you' : '$n nearby'}';
  }

  static void _update(PlopNode node) {
    final line = _line(node);
    if (line == _statusText) return;
    _statusText = line;
    _status?.label = line;
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
