import 'dart:io';

import 'package:flutter/foundation.dart';
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

  /// [onMessage] says how it went; [packing] is told of a folder being
  /// zipped, as a drop on the window is ([addPaths]).
  static Future<void> listen(
    PlopNode node,
    void Function(String message) onMessage, {
    void Function(String? folder)? packing,
  }) async {
    if (!Platform.isAndroid && !Platform.isMacOS) return;
    Future<void> ingest(Object? shared) async {
      if (shared is! Map) return;
      try {
        await take(node, shared, onMessage, packing: packing);
      } catch (e) {
        onMessage(friendlyError(e));
      }
    }

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shared') await ingest(call.arguments);
    });
    await ingest(await _channel.invokeMethod<Object?>('initial'));
  }

  /// Puts what was [shared] on the shelf and says how it went. Each path
  /// goes on its own, as a drop on the window does: one that fails (a
  /// folder over the cap, a file moved meanwhile) no longer keeps the rest
  /// off the shelf, and on Android their cache copies with them. Android
  /// hands over cache copies, which are plop's to delete with their items
  /// ([addCopy]); macOS hands over the user's own files.
  @visibleForTesting
  static Future<void> take(
    PlopNode node,
    Map<Object?, Object?> shared,
    void Function(String message) onMessage, {
    void Function(String? folder)? packing,
  }) async {
    final paths = [for (final p in shared['paths'] as List? ?? []) '$p'];
    final (added, first) = await addPaths(node, paths, packing: packing);
    // What Android could not even read, beside what would not go on.
    final failed = ((shared['failed'] as int?) ?? 0) + added;
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
    onMessage(
      addedMessage(failed, first) ??
          (failed > 0 ? 'plopped · $failed failed' : 'plopped'),
    );
  }
}
