import 'package:flutter/services.dart';
import 'package:plop_core/plop_core.dart';

import 'settings.dart';

/// Turns on the web shelf, for phones that cannot get the app (iPhones
/// without a paid Apple account), with the app's icon for their home
/// screens. [remember] keeps the node's port for the next launch, so the
/// address saved on a phone keeps working; a second instance (a dev build
/// beside the installed plop) shares the settings file and must not move
/// the installed plop's address.
Future<void> startWebShelf(
  PlopNode node,
  Settings settings, {
  required bool remember,
}) async {
  if (remember) settings.webPort = node.port;
  final icon = await rootBundle.load('assets/icon/icon.png');
  node.web
    ..enabled = true
    ..iconPng = icon.buffer.asUint8List(icon.offsetInBytes, icon.lengthInBytes);
}
