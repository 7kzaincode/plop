import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:plop_core/plop_core.dart';

import 'bonsoir_discovery.dart';
import 'grab.dart';
import 'hotkeys.dart';
import 'login_item.dart';
import 'notify.dart';
import 'settings.dart';
import 'share_in.dart';
import 'shelf_screen.dart';
import 'theme.dart';
import 'tray.dart';
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
  // Android's picker copies every pick into its own cache dir and leaves it;
  // copies made from now on go with their item (addCopy), this clears what
  // earlier builds left. Android only: on iOS it would empty all of tmp,
  // plop's own dirs included.
  if (Platform.isAndroid) {
    await FilePicker.clearTemporaryFiles().catchError((_) {});
  }
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
  Arrivals.watch(node);
  // Closing the window keeps plop in the tray once its icon is up; what
  // happens while the window is away is said with OS notifications.
  Tray.init(node).ignore();
  Notify.init(settings).ignore();
  Notify.watch(node);
  // The shortcuts fire while the user is in another app or the window is
  // closed (macOS keeps plop running), so a failure that needs the user, like
  // the Screen Recording steps, waits until they look instead of fading out;
  // one that hands them something to tap waits for the tap.
  void say(
    String msg, {
    bool ok = true,
    String? action,
    void Function()? onTap,
  }) => screen.currentState?.toast(
    msg,
    action: action,
    onTap: onTap,
    sticky:
        !ok &&
        (onTap != null ||
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed),
  );
  Hotkeys.snip = settings.hotkey('snip') ?? Hotkeys.defaultSnip;
  Hotkeys.clip = settings.hotkey('clip') ?? Hotkeys.defaultClip;
  try {
    await Hotkeys.register(node, say);
  } catch (_) {
    // The plugin or its channel is missing (no keybinder on Linux, say). A
    // combo another app owns never throws; see Hotkeys.isFree.
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
