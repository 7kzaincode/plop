import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:plop_core/plop_core.dart';
import 'package:share_plus/share_plus.dart';

final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// desktop_drop has no iOS support; on Android it is only a preview.
final canDrop = isDesktop;

Future<List<String>> pickFiles() async {
  final files = await FilePicker.pickFiles();
  return [for (final f in files) ?f.path];
}

Widget wrapDropTarget({
  required Widget child,
  required void Function(bool hovering) onHover,
  required void Function(List<String> paths) onDrop,
}) {
  if (!canDrop) return child;
  return DropTarget(
    onDragEntered: (_) => onHover(true),
    onDragExited: (_) => onHover(false),
    onDragDone: (details) async {
      onHover(false);
      final paths = <String>[];
      for (final item in details.files) {
        if (item is DropItemDirectory) continue;
        // Files dropped from outside the macOS sandbox need their bookmark
        // opened. Access is kept for the app's lifetime, since the file is
        // served in place until it expires.
        final bookmark = item.extraAppleBookmark;
        if (Platform.isMacOS && bookmark != null && bookmark.isNotEmpty) {
          await DesktopDrop.instance.startAccessingSecurityScopedResource(
            bookmark: bookmark,
          );
        }
        paths.add(item.path);
      }
      if (paths.isNotEmpty) onDrop(paths);
    },
    child: child,
  );
}

/// Puts whatever is on the clipboard on the shelf: copied files, an image, or
/// text. Returns false if there was nothing usable.
Future<bool> pasteInto(PlopNode node) async {
  if (isDesktop) {
    final files = await _try(Pasteboard.files) ?? const <String>[];
    final local = [
      for (final f in files)
        if (File(f).existsSync()) f,
    ];
    if (local.isNotEmpty) {
      for (final f in local) {
        await node.addFile(f);
      }
      return true;
    }
  }
  final image = await _try(() => Pasteboard.image);
  if (image != null && image.isNotEmpty) {
    // pasteboard hands back BMP on Windows and PNG elsewhere.
    final ext = Platform.isWindows ? 'bmp' : 'png';
    await node.addBytes(image, 'Pasted image ${_stamp()}.$ext');
    return true;
  }
  final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  if (text != null && text.trim().isNotEmpty) {
    await node.addText(text);
    return true;
  }
  return false;
}

/// One tap on a peer's item. Text is copied; files are saved to Downloads on
/// desktop and handed to the share sheet on mobile. Returns a message to show.
Future<String?> grab(
  BuildContext context,
  PlopNode node,
  ShelfItem item,
) async {
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  final path = await node.fetch(item.key);

  if (item.kind == ItemKind.text) {
    await Clipboard.setData(
      ClipboardData(text: await File(path).readAsString()),
    );
    return 'Copied';
  }
  if (isDesktop) {
    final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
    await dir.create(recursive: true);
    final dest = _unique(dir, item.name);
    await File(path).copy(dest.path);
    return 'Saved to ${dest.path}';
  }
  await SharePlus.instance.share(
    ShareParams(
      files: [XFile(path, mimeType: item.mime)],
      sharePositionOrigin: origin,
    ),
  );
  return null;
}

String friendlyError(Object e) => switch (e) {
  ItemTooLargeException(:final max) =>
    'Too big. The limit is ${max ~/ (1024 * 1024 * 1024)} GB.',
  StateError(message: 'item expired') => 'That item has expired.',
  StateError(message: 'sender is gone') => 'The sender is no longer reachable.',
  _ => 'Could not get it. Is the sender still on this Wi-Fi with plop open?',
};

Future<String> deviceName() async {
  final info = DeviceInfoPlugin();
  try {
    if (Platform.isMacOS) return (await info.macOsInfo).computerName;
    if (Platform.isWindows) return (await info.windowsInfo).computerName;
    if (Platform.isAndroid) {
      final a = await info.androidInfo;
      return a.name.isNotEmpty ? a.name : '${a.manufacturer} ${a.model}';
    }
    if (Platform.isIOS) {
      // iOS 16+ only reveals "iPhone"/"iPad" as the device name.
      return (await info.iosInfo).modelName;
    }
  } catch (_) {}
  return Platform.localHostname;
}

File _unique(Directory dir, String name) {
  final safe = safeFileName(name);
  final dot = safe.lastIndexOf('.');
  final base = dot > 0 ? safe.substring(0, dot) : safe;
  final ext = dot > 0 ? safe.substring(dot) : '';
  var f = File('${dir.path}${Platform.pathSeparator}$safe');
  for (var n = 1; f.existsSync(); n++) {
    f = File('${dir.path}${Platform.pathSeparator}$base ($n)$ext');
  }
  return f;
}

String _stamp() {
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.hour)}.${two(t.minute)}.${two(t.second)}';
}

Future<T?> _try<T>(Future<T> Function() f) async {
  try {
    return await f();
  } catch (_) {
    return null;
  }
}
