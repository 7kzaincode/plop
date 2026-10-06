import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

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

final _sep = Platform.pathSeparator;

/// A message meant for the user as is.
class PlopMessage implements Exception {
  const PlopMessage(this.message);
  final String message;
  @override
  String toString() => message;
}

// ---------------------------------------------------------------- adding

/// [media] opens the photo library on mobile, where screenshots live.
Future<List<String>> pickFiles({bool media = false}) async {
  if (Platform.isMacOS && !media) {
    // One panel that takes files and folders alike.
    return FilePicker.pickFileAndDirectoryPaths();
  }
  final files = await FilePicker.pickFiles(
    type: media ? FileType.media : FileType.any,
    // iPhone photos travel as JPEG/H.264, which every PC can open.
    darwinOptions: const DarwinOptions(
      assetRepresentationMode: DarwinAssetRepresentationMode.compatible,
    ),
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

final _link = RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false);

/// Puts whatever is on the clipboard on the shelf: copied files or folders,
/// an image, or text. Returns false if there was nothing usable.
Future<bool> pasteInto(PlopNode node) async {
  final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
  // U+FFFC is what AppKit writes as plain text for an image attachment.
  final t = text.replaceAll('￼', '').trim();
  final isLink =
      !t.contains(RegExp(r'\s')) &&
      _link.hasMatch(t) &&
      !t.toLowerCase().startsWith('file:');
  // pasteboard's macOS files() turns any URL, web links too, into a path
  // (https://site.com/ comes back as "/"), so never trust it for a link.
  if (isDesktop && !isLink) {
    final local = [
      for (final f in await _try(Pasteboard.files) ?? const <String>[])
        if (f != '/' &&
            FileSystemEntity.typeSync(f) != FileSystemEntityType.notFound)
          f,
    ];
    if (local.isNotEmpty) {
      for (final f in local) {
        await node.addPath(f);
      }
      return true;
    }
  }
  // Take an image only when there is no real text: Word, Excel and Pages put
  // a picture of copied text on the clipboard too.
  if (t.isEmpty || isLink) {
    final image = await _try(() => Pasteboard.image);
    if (image != null && image.isNotEmpty) {
      await addImageBytes(node, image);
      return true;
    }
  }
  if (t.isNotEmpty) {
    await node.addText(text);
    return true;
  }
  return false;
}

Future<ShelfItem> addImageBytes(
  PlopNode node,
  Uint8List bytes, {
  String prefix = 'Image',
}) async {
  // pasteboard hands back an uncompressed BMP on Windows (33 MB at 4K).
  if (Platform.isWindows) bytes = await toPng(bytes);
  return node.addBytes(bytes, '$prefix ${stamp()}.${imageExt(bytes)}');
}

/// The extension for image bytes, from their magic number. Android's
/// clipboard hands over whatever the source app wrote (Chrome and Gboard
/// often JPEG or WebP) where every other platform re-encodes to PNG, and the
/// name decides the wire mime and whether a Windows receiver tries to copy
/// it as a picture, which GDI+ can't do for WebP or HEIC.
String imageExt(Uint8List b) {
  bool at(int i, List<int> sig) {
    if (b.length < i + sig.length) return false;
    for (var k = 0; k < sig.length; k++) {
      if (b[i + k] != sig[k]) return false;
    }
    return true;
  }

  if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) return 'webp';
  if (at(0, const [0xFF, 0xD8, 0xFF])) return 'jpg';
  if (at(0, 'GIF8'.codeUnits)) return 'gif';
  if (at(0, 'BM'.codeUnits)) return 'bmp';
  if (at(4, 'ftyp'.codeUnits)) return 'heic'; // ISO BMFF
  return 'png';
}

/// Re-encodes any image Flutter can decode as PNG.
Future<Uint8List> toPng(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}

// ---------------------------------------------------------------- grabbing

/// What a tap on an item does.
enum GrabAction { copy, save, share }

bool isCopyableImage(ShelfItem item) =>
    categoryOf(item) == FileCategory.image &&
    !item.name.toLowerCase().endsWith('.svg');

/// Whether this OS's clipboard can take the item as a picture. Windows goes
/// through GDI+ and Android through BitmapFactory, which can't read HEIC,
/// WebP or RAW; a failed attempt on Windows also empties the clipboard.
bool _copiesAsImage(ShelfItem item) {
  if (!isCopyableImage(item) || Platform.isLinux) return false;
  if (Platform.isMacOS || Platform.isIOS) return true;
  final ext = item.name.split('.').last.toLowerCase();
  return const {'png', 'jpg', 'jpeg', 'gif', 'bmp'}.contains(ext) &&
      !(Platform.isAndroid && item.size > 25 * 1024 * 1024);
}

/// The actions a row offers, default (tap) first.
List<GrabAction> actionsFor(ShelfItem item) {
  if (item.kind == ItemKind.text) return const [GrabAction.copy];
  if (isDesktop) {
    if (item.kind == ItemKind.folder) return const [GrabAction.save];
    if (_copiesAsImage(item)) return const [GrabAction.copy, GrabAction.save];
    return const [GrabAction.save, GrabAction.copy];
  }
  if (_copiesAsImage(item)) return const [GrabAction.copy, GrabAction.share];
  return const [GrabAction.share];
}

/// Copies an item to the clipboard or shares it, returning a confirmation.
/// Saving goes through [saveItem], which returns the path instead.
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
      return 'saved to ${_parentName(await saveItem(node, item))}';
    case GrabAction.share:
      final path = await _materialize(node, item);
      try {
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(path, mimeType: item.mime)],
            sharePositionOrigin: origin,
          ),
        );
      } finally {
        // The share sheet has made its own copy by now.
        _deleteLater(File(path).parent);
      }
      return null;
  }
}

/// The clipboard can only point at one file, so only the latest copy is kept.
Directory? _lastCopy;

Future<String> _copy(PlopNode node, ShelfItem item) async {
  if (item.kind == ItemKind.text) {
    final text = await File(await node.fetch(item.key)).readAsString();
    await Clipboard.setData(ClipboardData(text: text));
    return 'copied';
  }
  if (_copiesAsImage(item)) {
    final bytes = await File(await node.fetch(item.key)).readAsBytes();
    try {
      await Pasteboard.writeImage(bytes);
      return 'image copied';
    } on PlatformException {
      if (!isDesktop) throw const PlopMessage("couldn't copy that · try share");
      // Fall back to copying it as a file below.
    }
  }
  final path = await _materialize(node, item);
  // pasteboard's Windows writeFiles never empties the clipboard first.
  if (Platform.isWindows) {
    await Clipboard.setData(const ClipboardData(text: ''));
  }
  if (!await Pasteboard.writeFiles([path])) {
    throw const PlopMessage("couldn't use the clipboard · try save");
  }
  if (_lastCopy != null) _deleteLater(_lastCopy!);
  _lastCopy = File(path).parent;
  return 'copied · paste it anywhere';
}

/// Saves an item to Downloads (folders unpacked) and returns where it went.
Future<String> saveItem(PlopNode node, ShelfItem item) async {
  final dir = await getDownloadsDirectory() ?? await getTemporaryDirectory();
  await dir.create(recursive: true);
  if (item.kind == ItemKind.folder) {
    final zip = '${outDir.path}$_sep${randomId()}.zip';
    await node.saveTo(item.key, zip);
    final dest = _unique(dir, item.name, folder: true);
    try {
      await extractFolder(zip, dest);
    } finally {
      _deleteLater(File(zip));
    }
    return dest;
  }
  final dest = _unique(dir, item.name);
  await node.saveTo(item.key, dest);
  return dest;
}

/// Shows a saved file in Finder, Explorer or the file manager.
Future<void> reveal(String path) async {
  try {
    // The sandbox's Downloads is a link to the real ~/Downloads.
    path = File(path).resolveSymbolicLinksSync();
  } catch (_) {}
  if (Platform.isMacOS) {
    await Process.run('/usr/bin/open', ['-R', path]);
  } else if (Platform.isWindows) {
    await Process.run('explorer.exe', ['/select,', path]);
  } else if (Platform.isLinux) {
    await Process.run('xdg-open', [File(path).parent.path]);
  }
}

/// A copy of the item in [outDir] that is not deleted when the item expires.
/// Folders stay zipped.
Future<String> _materialize(PlopNode node, ShelfItem item) async {
  final dir = Directory('${outDir.path}$_sep${randomId()}')..createSync();
  final name = safeFileName(item.name);
  final dest = item.kind == ItemKind.folder
      ? '${dir.path}$_sep$name.zip'
      : '${dir.path}$_sep$name';
  await node.saveTo(item.key, dest);
  return dest;
}

String friendlyError(Object e) => switch (e) {
  PlopMessage(:final message) => message,
  ItemTooLargeException(:final max) =>
    'too big · the limit is ${max ~/ (1024 * 1024 * 1024)} GB',
  StateError(message: 'item expired') => 'that one expired',
  StateError(message: 'sender is gone') => 'the sender is no longer reachable',
  SocketException() ||
  HttpException() ||
  TimeoutException() ||
  StateError() => 'could not get it · is the sender still here?',
  FileSystemException(:final path?) =>
    "can't access ${path.split(RegExp(r'[/\\]')).last.replaceAll(RegExp(r'\.part$'), '')}",
  _ => "that didn't work",
};

Future<String> deviceName() async {
  final info = DeviceInfoPlugin();
  try {
    if (Platform.isMacOS) return (await info.macOsInfo).computerName;
    if (Platform.isWindows) {
      final w = await info.windowsInfo;
      final host = w.computerName.split('.').first;
      // Most PCs keep their factory name, e.g. DESKTOP-8F3K2LQ.
      final generic = RegExp(
        r'^(desktop|laptop)-[a-z0-9]+$',
        caseSensitive: false,
      ).hasMatch(host);
      return generic && w.userName.isNotEmpty ? "${w.userName}'s PC" : host;
    }
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
  String at(String n) => '${dir.path}$_sep$n';
  var p = at(safe);
  for (
    var n = 1;
    FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound ||
        File('$p.part').existsSync();
    n++
  ) {
    p = at('$base ($n)$ext');
  }
  return p;
}

String _parentName(String path) {
  final parts = path.split(_sep);
  return parts.length < 2 ? path : parts[parts.length - 2];
}

void _deleteLater(FileSystemEntity e) =>
    e.delete(recursive: true).then((_) {}, onError: (_) {});

String stamp() {
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
