import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
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
/// A photo taken now with the phone's camera, or none if the user backs out.
Future<List<String>> takePhoto() async {
  final shot = await ImagePickerPlatform.instance.getImageFromSource(
    source: ImageSource.camera,
  );
  return [?shot?.path];
}

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

/// Puts a file that is plop's own copy on the shelf. Phones' pickers and
/// Share-to-plop hand over a copy in the app cache rather than the user's
/// file, and the store serves a picked path in place and only ever deletes
/// files it made, so without this every shared photo and video stayed in
/// the cache until the OS purged it. The copy goes when its item does
/// (expiry or ✕). Desktop pickers return the user's real files: not for them.
Future<ShelfItem> addCopy(PlopNode node, String path) async {
  final ShelfItem item;
  try {
    item = await node.addPath(path);
  } catch (_) {
    _deleteCopy(path); // too big, say: nothing will ever refer to it
    rethrow;
  }
  _copies[item.key] = path;
  _copyWatch ??= node.store.localChanges.listen((_) {
    final live = {for (final i in node.items) i.key};
    for (final key in [..._copies.keys]) {
      if (!live.contains(key)) _deleteCopy(_copies.remove(key)!);
    }
  });
  return item;
}

final _copies = <String, String>{};
StreamSubscription<void>? _copyWatch;

/// Puts each of [paths] on the shelf, carrying on past any that fail (a
/// folder over the cap, a file moved meanwhile): how many failed, and the
/// first error. Desktop paths are the user's own files, served in place;
/// a phone's are plop's copies ([addCopy]). [packing] is told the name of
/// a folder before it is zipped, which takes a while before its row
/// appears, and null once all are done, however they went. A disk's root
/// ("/", the startup disk dropped from the Finder sidebar) fails on its
/// own, unzipped: zipping a whole disk would run for hours before the cap
/// turned it away.
Future<(int failed, Object? first)> addPaths(
  PlopNode node,
  List<String> paths, {
  void Function(String? folder)? packing,
}) async {
  Object? first;
  var failed = 0;
  try {
    for (final p in paths) {
      final name = p
          .split(RegExp(r'[/\\]'))
          .lastWhere((s) => s.isNotEmpty, orElse: () => '');
      try {
        if (name.isEmpty) {
          throw const PlopMessage("that's a whole disk · plop a folder on it");
        }
        if (await FileSystemEntity.isDirectory(p)) packing?.call(name);
        await (isDesktop ? node.addPath(p) : addCopy(node, p));
      } catch (e) {
        failed++;
        first ??= e;
      }
    }
  } finally {
    packing?.call(null);
  }
  return (failed, first);
}

/// What to say after [addPaths]: nothing if all went on the shelf, else
/// the first error, and how many more failed.
String? addedMessage(int failed, Object? first) {
  if (first == null) return null;
  final why = friendlyError(first);
  return failed > 1 ? '$why · ${failed - 1} more failed' : why;
}

void _deleteCopy(String path) {
  final f = File(path);
  // The copy sits in a per-pick directory; a non-recursive delete leaves
  // the directory alone while another file from the same share is listed.
  f.delete().then((_) => f.parent.delete()).then((_) {}, onError: (_) {});
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
  if (at(4, 'ftyp'.codeUnits)) {
    // ISO BMFF: the brand at bytes 8-11 tells AVIF from HEIC.
    return at(8, 'avi'.codeUnits) ? 'avif' : 'heic';
  }
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
/// WebP or RAW; a failed attempt on Windows also empties the clipboard. Any
/// other picture is copied as a file, as a file is. macOS and iOS read
/// pictures through ImageIO, which takes most kinds but not all (AVIF
/// before macOS 13 and iOS 16, some cameras' RAW, a file that is no
/// picture whatever its name says): no list here, [copyItem] checks each
/// one's header as it copies. Copying arrivals (lib/auto_copy.dart) takes
/// only what this says yes to.
bool copiesAsImage(ShelfItem item) {
  final os = debugClipboardOs ?? Platform.operatingSystem;
  if (!isCopyableImage(item) || os == 'linux') return false;
  if (os == 'macos' || os == 'ios') return true;
  final ext = item.name.split('.').last.toLowerCase();
  return const {'png', 'jpg', 'jpeg', 'gif', 'bmp'}.contains(ext) &&
      !(os == 'android' && item.size > 25 * 1024 * 1024);
}

/// Tests set this to an OS name (as [Platform.operatingSystem] gives it)
/// to see what that OS's clipboard takes as a picture, and back.
@visibleForTesting
String? debugClipboardOs;

/// The actions a row offers, default (tap) first.
List<GrabAction> actionsFor(ShelfItem item) {
  if (item.kind == ItemKind.text) return const [GrabAction.copy];
  if (isDesktop) {
    if (item.kind == ItemKind.folder) return const [GrabAction.save];
    if (copiesAsImage(item)) return const [GrabAction.copy, GrabAction.save];
    return const [GrabAction.save, GrabAction.copy];
  }
  if (copiesAsImage(item)) return const [GrabAction.copy, GrabAction.share];
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
      return copyItem(node, item);
    case GrabAction.save:
      return 'saved to ${savedWhere(await saveItem(node, item))}';
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

/// Puts [item] on the clipboard as the row's copy does: text as text, a
/// picture as a picture, anything else as the file. Returns what to say.
/// A picture the clipboard turns out not to take goes as the file too on
/// desktop, unless [orFile] is false: copying arrivals never puts a file
/// on the clipboard, and fails instead.
Future<String> copyItem(
  PlopNode node,
  ShelfItem item, {
  bool orFile = true,
}) async {
  if (item.kind == ItemKind.text) {
    final text = await File(await node.fetch(item.key)).readAsString();
    await Clipboard.setData(ClipboardData(text: text));
    return 'copied';
  }
  if (copiesAsImage(item)) {
    final bytes = await File(await node.fetch(item.key)).readAsBytes();
    try {
      // pasteboard never says a picture failed to decode on macOS or iOS:
      // it empties the clipboard and writes a blank NSImage, or a nil
      // UIImage. Flutter's codec falls back to the same ImageIO there for
      // what it can't read itself, so ask it first whether it knows the
      // kind. It reads the header only, no frame: a picture cut short
      // still passes, as NSImage would take it too. A codec that says no
      // throws an Exception, as a PlatformException from the write does.
      (await ui.instantiateImageCodec(bytes)).dispose();
      await Pasteboard.writeImage(bytes);
      return 'image copied';
    } on Exception {
      if (!isDesktop || !orFile) {
        throw const PlopMessage("couldn't copy that · try share");
      }
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
  final dir =
      debugDownloads ??
      await getDownloadsDirectory() ??
      await getTemporaryDirectory();
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

/// Tests set this to save into a folder of their own rather than the real
/// Downloads, which path_provider finds on its own on some hosts (Linux).
@visibleForTesting
Directory? debugDownloads;

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
  // extractFolder refuses a zip plop would never have made (compressed, or
  // one that unpacks to more than it says): a zip bomb or a foreign peer.
  FormatException() => "that folder isn't something plop made",
  SocketException() ||
  HttpException() ||
  TimeoutException() ||
  TransferInterrupted() ||
  StateError() => "couldn't get it · is the sender still here?",
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

/// The folder a save landed in, as a confirmation names it.
String savedWhere(String path) {
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
