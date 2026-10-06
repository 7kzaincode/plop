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

import 'type_icons.dart';

bool get isDesktop =>
    debugDesktopOverride ??
    (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// Tests set this to lay out the phone UI on a desktop host, and back.
bool? debugDesktopOverride;

/// desktop_drop has no iOS support; on Android it is only a preview.
bool get canDrop => isDesktop;

/// Scratch space for grabbed items that must outlive the shelf entry (files
/// handed to the clipboard or share sheet). Set by main, wiped on launch.
late Directory outDir;

// ---------------------------------------------------------------- adding

/// [media] opens the photo library on mobile, where screenshots live.
Future<List<String>> pickFiles({bool media = false}) async {
  if (Platform.isMacOS && !media) {
    // One panel that takes files and folders alike.
    return FilePicker.pickFileAndDirectoryPaths();
  }
  final files = await FilePicker.pickFiles(
    type: media ? FileType.media : FileType.any,
  );
  return [for (final f in files) ?f.path];
}

Future<List<String>> pickFolder() async {
  final dir = await FilePicker.getDirectoryPath();
  return [?dir];
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

/// Puts whatever is on the clipboard on the shelf: copied files or folders,
/// an image, or text. Returns false if there was nothing usable.
Future<bool> pasteInto(PlopNode node) async {
  if (isDesktop) {
    final copied = await _try(Pasteboard.files) ?? const <String>[];
    final local = [
      for (final f in copied)
        if (FileSystemEntity.typeSync(f) != FileSystemEntityType.notFound) f,
    ];
    if (local.isNotEmpty) {
      for (final f in local) {
        await node.addPath(f);
      }
      return true;
    }
  }
  final image = await _try(() => Pasteboard.image);
  if (image != null && image.isNotEmpty) {
    await addImageBytes(node, image);
    return true;
  }
  final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  if (text != null && text.trim().isNotEmpty) {
    await node.addText(text);
    return true;
  }
  return false;
}

Future<ShelfItem> addImageBytes(PlopNode node, List<int> bytes) {
  // pasteboard hands back BMP on Windows and PNG elsewhere.
  final ext = Platform.isWindows ? 'bmp' : 'png';
  return node.addBytes(bytes, 'Image ${_stamp()}.$ext');
}

// ---------------------------------------------------------------- grabbing

/// What a plain tap on a peer's item does.
enum GrabAction { copy, save, share }

bool isCopyableImage(ShelfItem item) =>
    categoryOf(item) == FileCategory.image &&
    !item.name.toLowerCase().endsWith('.svg');

/// The actions a row offers, default (tap) first.
List<GrabAction> actionsFor(ShelfItem item) {
  if (item.kind == ItemKind.text) return const [GrabAction.copy];
  if (isDesktop) {
    if (item.kind == ItemKind.folder) return const [GrabAction.save];
    if (isCopyableImage(item)) return const [GrabAction.copy, GrabAction.save];
    return const [GrabAction.save, GrabAction.copy];
  }
  if (isCopyableImage(item)) return const [GrabAction.copy, GrabAction.share];
  return const [GrabAction.share];
}

/// Runs [action] on a peer's item and returns a short confirmation.
Future<String?> grab(
  BuildContext context,
  PlopNode node,
  ShelfItem item,
  GrabAction action,
) async {
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  switch (action) {
    case GrabAction.copy:
      return _copy(node, item);
    case GrabAction.save:
      return _save(node, item);
    case GrabAction.share:
      final path = await _materialize(node, item, extract: false);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, mimeType: item.mime)],
          sharePositionOrigin: origin,
        ),
      );
      return null;
  }
}

Future<String> _copy(PlopNode node, ShelfItem item) async {
  if (item.kind == ItemKind.text) {
    final text = await File(await node.fetch(item.key)).readAsString();
    await Clipboard.setData(ClipboardData(text: text));
    return 'copied';
  }
  // Linux has no image clipboard in pasteboard; fall through to a file copy.
  if (isCopyableImage(item) && !Platform.isLinux) {
    final bytes = await File(await node.fetch(item.key)).readAsBytes();
    await Pasteboard.writeImage(bytes);
    return 'image copied';
  }
  final path = await _materialize(node, item, extract: true);
  await Pasteboard.writeFiles([path]);
  return 'copied · paste it anywhere';
}

Future<String> _save(PlopNode node, ShelfItem item) async {
  final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
  await dir.create(recursive: true);
  if (item.kind == ItemKind.folder) {
    final zip = '${outDir.path}/${randomId()}.zip';
    await node.saveTo(item.key, zip);
    final dest = _unique(dir, item.name, folder: true);
    await extractFolder(zip, dest);
    await File(zip).delete();
    return 'saved to ${_short(dest)}';
  }
  final dest = _unique(dir, item.name);
  await node.saveTo(item.key, dest);
  return 'saved to ${_short(dest)}';
}

/// A copy of the item in [outDir] that is not deleted when the item expires.
/// Folders are unpacked when [extract] is set.
Future<String> _materialize(
  PlopNode node,
  ShelfItem item, {
  required bool extract,
}) async {
  final dir = Directory('${outDir.path}/${randomId()}')..createSync();
  if (item.kind == ItemKind.folder) {
    final zip = '${dir.path}/${safeFileName(item.name)}.zip';
    await node.saveTo(item.key, zip);
    if (!extract) return zip;
    final dest = '${dir.path}/${safeFileName(item.name)}';
    await extractFolder(zip, dest);
    return dest;
  }
  final dest = '${dir.path}/${safeFileName(item.name)}';
  await node.saveTo(item.key, dest);
  return dest;
}

String friendlyError(Object e) => switch (e) {
  ItemTooLargeException(:final max) =>
    'too big · the limit is ${max ~/ (1024 * 1024 * 1024)} GB',
  StateError(message: 'item expired') => 'that one expired',
  StateError(message: 'sender is gone') => 'the sender is no longer reachable',
  _ => 'could not get it · is the sender still here?',
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

String _unique(Directory dir, String name, {bool folder = false}) {
  final safe = safeFileName(name);
  final dot = folder ? -1 : safe.lastIndexOf('.');
  final base = dot > 0 ? safe.substring(0, dot) : safe;
  final ext = dot > 0 ? safe.substring(dot) : '';
  String at(String n) => '${dir.path}${Platform.pathSeparator}$n';
  var p = at(safe);
  for (
    var n = 1;
    FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound;
    n++
  ) {
    p = at('$base ($n)$ext');
  }
  return p;
}

String _short(String path) {
  final parts = path.split(Platform.pathSeparator);
  return parts.length < 2 ? path : parts.sublist(parts.length - 2).join('/');
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
