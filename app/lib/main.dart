import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:plop_core/plop_core.dart';

import 'bonsoir_discovery.dart';
import 'grab.dart';
import 'shelf_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // PLOP_INSTANCE lets two copies run side by side on one machine (each needs
  // its own scratch dir, since the dir is wiped on launch).
  final instance = Platform.environment['PLOP_INSTANCE'];
  final tmp = await getTemporaryDirectory();
  final dir = Directory(
    '${tmp.path}${Platform.pathSeparator}plop${instance == null ? '' : '-$instance'}',
  );
  var name = await deviceName();
  if (instance != null) name = '$name ($instance)';

  final node = await PlopNode.start(
    dir: dir,
    discovery: BonsoirPeerDiscovery(),
    name: name,
  );
  if (kDebugMode) await _seed(node);
  runApp(PlopApp(node: node));
}

/// Debug builds only: put something on the shelf at launch, for testing
/// without clicking through the UI.
Future<void> _seed(PlopNode node) async {
  final env = Platform.environment;
  if (env['PLOP_SEED_TEXT'] case final t?) await node.addText(t);
  if (env['PLOP_SEED_FILE'] case final f?) await node.addFile(f);
}

class PlopApp extends StatelessWidget {
  const PlopApp({super.key, required this.node});

  final PlopNode node;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF3B6EF5),
        brightness: b,
      ),
    );
    return MaterialApp(
      title: 'plop',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: ShelfScreen(node: node),
    );
  }
}
