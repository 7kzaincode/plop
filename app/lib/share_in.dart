import 'dart:io';

import 'package:flutter/services.dart';
import 'package:plop_core/plop_core.dart';

import 'grab.dart';

/// Android "Share to plop": MainActivity copies shared files into the cache
/// and passes their paths (or shared text) over this channel. The copies
/// are plop's own, so they go when their items do (see addCopy).
abstract final class ShareIn {
  static const _channel = MethodChannel('plop/share');

  static Future<void> listen(
    PlopNode node,
    void Function(String message) onMessage,
  ) async {
    if (!Platform.isAndroid) return;
    Future<void> ingest(Object? shared) async {
      if (shared is! Map) return;
      try {
        final failed = (shared['failed'] as int?) ?? 0;
        final paths = [for (final p in shared['paths'] as List? ?? []) '$p'];
        for (final p in paths) {
          await addCopy(node, p);
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
