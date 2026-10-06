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
        final failed = (shared['failed'] as int?) ?? 0;
        final paths = [for (final p in shared['paths'] as List? ?? []) '$p'];
        for (final p in paths) {
          // Android hands over cache copies, which are plop's to delete with
          // their items; macOS hands over the user's own files.
          await (Platform.isAndroid ? addCopy(node, p) : node.addPath(p));
        }
        // Text only stands in when no file could be read, so a caption must
        // not pass for the photo it came with.
        final text = '${shared['text'] ?? ''}';
        final gotText = paths.isEmpty && text.trim().isNotEmpty;
        if (gotText) await node.addText(text);
        if (paths.isEmpty && !gotText) {
          // The share sheet has closed; silence would look like nothing
          // happened.
          if (failed > 0) onMessage("couldn't read what was shared");
          return;
        }
        onMessage(failed > 0 ? 'plopped · $failed failed' : 'plopped');
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
