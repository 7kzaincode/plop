import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:plop_core/plop_core.dart';

import 'bonsoir_discovery.dart';
import 'grab.dart';
import 'hotkeys.dart';
import 'login_item.dart';
import 'settings.dart';
import 'share_in.dart';
import 'shelf_screen.dart';
import 'theme.dart';
import 'window.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MacWindow.init();
  try {
    await _start();
  } catch (e) {
    // Never leave a blank window: say what went wrong instead.
    runApp(_StartupError(e));
  }
}

Future<void> _start() async {
  // PLOP_INSTANCE lets two copies run side by side on one machine (each needs
  // its own scratch dirs, since they are wiped on launch).
  // Debug builds (flutter run) default to their own instance, so running
  // one beside the installed plop never wipes its scratch folders.
  final instance =
      Platform.environment['PLOP_INSTANCE'] ?? (kDebugMode ? 'dev' : null);
  final suffix = instance == null ? '' : '-$instance';
  final tmp = (await getTemporaryDirectory()).path;
  final sep = Platform.pathSeparator;
  outDir = Directory('$tmp${sep}plop-out$suffix');
  try {
    if (outDir.existsSync()) outDir.deleteSync(recursive: true);
  } on FileSystemException {
    // A file still open elsewhere (Windows); leftovers are harmless.
  }
  outDir.createSync(recursive: true);

  var name = await deviceName();
  if (instance != null) name = '$name ($instance)';
  final settings = await Settings.load();

  final node = await PlopNode.start(
    dir: Directory('$tmp${sep}plop$suffix'),
    discovery: BonsoirPeerDiscovery(),
    name: name,
    ttl: settings.ttl,
  );
  if (kDebugMode) await _seed(node);
  final screen = GlobalKey<ShelfScreenState>();
  runApp(PlopApp(node: node, settings: settings, screenKey: screen));
  LoginItem.installLauncher();
  void say(String msg) => screen.currentState?.toast(msg);
  Hotkeys.snip = settings.hotkey('snip') ?? Hotkeys.defaultSnip;
  Hotkeys.clip = settings.hotkey('clip') ?? Hotkeys.defaultClip;
  try {
    await Hotkeys.register(node, say);
  } catch (_) {
    // Another app owns the shortcut, or the platform has none.
  }
  await ShareIn.listen(node, say).catchError((_) {});
}

/// Debug builds only: put something on the shelf at launch, for testing
/// without clicking through the UI.
Future<void> _seed(PlopNode node) async {
  final env = Platform.environment;
  if (env['PLOP_SEED_TEXT'] case final t?) await node.addText(t);
  if (env['PLOP_SEED_FILE'] case final f?) await node.addPath(f);
}

class PlopApp extends StatelessWidget {
  const PlopApp({
    super.key,
    required this.node,
    required this.settings,
    this.screenKey,
  });

  final PlopNode node;
  final Settings settings;
  final GlobalKey<ShelfScreenState>? screenKey;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'plop',
    debugShowCheckedModeBanner: false,
    theme: plopTheme(),
    home: ShelfScreen(key: screenKey, node: node, settings: settings),
  );
}

class _StartupError extends StatelessWidget {
  const _StartupError(this.error);
  final Object error;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'plop',
    debugShowCheckedModeBanner: false,
    theme: plopTheme(),
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: SelectableText(
            "plop couldn't start\n\n$error"
            '${Platform.isLinux ? '\n\nis avahi-daemon running?' : ''}',
            textAlign: TextAlign.center,
            style: monoStyle(color: Palette.dim),
          ),
        ),
      ),
    ),
  );
}
