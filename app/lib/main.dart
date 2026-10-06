import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:plop_core/plop_core.dart';

import 'bonsoir_discovery.dart';
import 'grab.dart';
import 'hotkeys.dart';
import 'settings.dart';
import 'shelf_screen.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // PLOP_INSTANCE lets two copies run side by side on one machine (each needs
  // its own scratch dirs, since they are wiped on launch).
  final instance = Platform.environment['PLOP_INSTANCE'];
  final suffix = instance == null ? '' : '-$instance';
  final tmp = (await getTemporaryDirectory()).path;
  final sep = Platform.pathSeparator;
  outDir = Directory('$tmp${sep}plop-out$suffix');
  if (outDir.existsSync()) outDir.deleteSync(recursive: true);
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
  await Hotkeys.register(node, (msg) => screen.currentState?.toast(msg));
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
