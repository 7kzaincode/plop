import 'dart:io';

import 'package:flutter/services.dart';
import 'package:plop_core/plop_core.dart';

import 'grab.dart';

/// Things the OS hands to plop: Android "Share to plop" (MainActivity copies
/// shared files into the cache and passes their paths, or the shared text)
/// and files dropped on the macOS Dock icon (MainFlutterWindow passes their
/// paths). Both answer "initial" with what arrived before Dart listened and
/// push later arrivals as "shared".
abstract final class ShareIn {
  static const _channel = MethodChannel('plop/share');

  static Future<void> listen(
    PlopNode node,
    void Function(String message) onMessage,
  ) async {
    if (!Platform.isAndroid && !Platform.isMacOS) return;
    Future<void> ingest(Object? shared) async {
      if (shared is! Map) return;
      try {
        final paths = [for (final p in shared['paths'] as List? ?? []) '$p'];
        for (final p in paths) {
          await node.addPath(p);
        }
        final text = '${shared['text'] ?? ''}';
        if (paths.isEmpty && text.trim().isNotEmpty) await node.addText(text);
        if (paths.isNotEmpty || text.trim().isNotEmpty) onMessage('plopped');
      } catch (e) {
        onMessage(friendlyError(e));
      }
    }

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shared') await ingest(call.arguments);
    });
    await ingest(await _channel.invokeMethod<Object?>('initial'));
  }
}
