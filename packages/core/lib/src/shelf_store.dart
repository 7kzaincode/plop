import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';

import 'item.dart';

/// Unpacks a folder item's zip into [outDir]. Only plain files and folders
/// are written: symlinks are skipped (plop never sends them, and a chain of
/// them can steer later entries outside [outDir]), as are names with `..`.
Future<void> extractFolder(String zipPath, String outDir) =>
    Isolate.run(() async {
      await Directory(outDir).create(recursive: true);
      final input = InputFileStream(zipPath);
      try {
        for (final f in ZipDecoder().decodeStream(input)) {
          final parts = f.name.split(RegExp(r'[/\\]'))
            ..removeWhere((s) => s.isEmpty || s == '.');
          if (f.isSymbolicLink || parts.isEmpty || parts.contains('..')) {
            continue;
          }
          final path = [outDir, ...parts].join(Platform.pathSeparator);
          if (f.isDirectory) {
            await Directory(path).create(recursive: true);
            continue;
          }
          final out = OutputFileStream(path); // creates parent folders
          try {
            f.writeContent(out);
          } finally {
            await out.close();
          }
        }
      } finally {
        await input.close();
      }
    });

/// Writes the contents of [dir] to [zip]. Entries are stored with
/// [CompressionType.none], which the archive package streams; it would
/// deflate anything else into memory whole. Links are skipped, not followed:
/// they can point outside the folder.
Future<void> _zipFolder(String dir, String zip, int maxBytes) async {
  final entries = Directory(dir).listSync(recursive: true, followLinks: false);
  // Refuse before writing anything rather than after copying it all.
  final total = entries.whereType<File>().fold(0, (n, f) => n + f.lengthSync());
  if (total > maxBytes) throw ItemTooLargeException(total, maxBytes);
  final enc = ZipFileEncoder()..create(zip);
  for (final e in entries) {
    final name = e.path
        .substring(dir.length)
        .replaceFirst(RegExp(r'^[/\\]+'), '');
    final ArchiveFile f;
    if (e is File) {
      f = ArchiveFile.stream(name, InputFileStream(e.path))
        ..lastModTime = e.lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
    } else if (e is Directory) {
      f = ArchiveFile.directory(name);
    } else {
      continue; // a link
    }
    // Folder entries too: an empty "deflated" entry is invalid to unzip.
    enc.addArchiveFile(f..compression = CompressionType.none);
  }
  await enc.close();
}

class ItemTooLargeException implements Exception {
  ItemTooLargeException(this.size, this.max);
  final int size;
  final int max;
  @override
  String toString() => 'Item is $size bytes; the limit is $max.';
}

/// All items this node knows about, with a timer per item that removes it
/// (and any file it owns) when its time runs out.
class ShelfStore {
  ShelfStore({
    required this.nodeId,
    required this.nodeName,
    required this.dir,
    this.ttl = defaultTtl,
    this.maxItemBytes = defaultMaxItemBytes,
  });

  final String nodeId;
  final String nodeName;

  /// Scratch directory owned by this store. Wiped by [init].
  final Directory dir;

  /// Lifetime given to items added from now on.
  Duration ttl;
  final int maxItemBytes;

  final _items = <String, ShelfItem>{};
  final _timers = <String, Timer>{};
  final _changes = StreamController<void>.broadcast();
  final _localChanges = StreamController<void>.broadcast();

  /// Fires on any change, including download progress.
  Stream<void> get changes => _changes.stream;

  /// Fires when this node's own items are added or removed.
  Stream<void> get localChanges => _localChanges.stream;

  /// Newest first.
  List<ShelfItem> get items =>
      _items.values.toList()
        ..sort((a, b) => b.expiresAt.compareTo(a.expiresAt));

  Iterable<ShelfItem> get localItems =>
      _items.values.where((i) => i.originId == nodeId);

  Iterable<ShelfItem> mirrorsOf(String peerId) =>
      _items.values.where((i) => i.originId == peerId).toList();

  ShelfItem? operator [](String key) => _items[key];
  ShelfItem? local(String id) => _items[itemKey(nodeId, id)];

  Future<void> init() async {
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
  }

  /// Puts a file or folder on the shelf.
  Future<ShelfItem> addPath(String path) async =>
      await FileSystemEntity.isDirectory(path)
      ? addFolder(path)
      : addFile(path);

  /// Puts a file on the shelf. The file is served in place, not copied.
  Future<ShelfItem> addFile(String path, {String? name}) async {
    final size = await File(path).length();
    _checkSize(size);
    name ??= _baseName(path);
    return _addLocal(
      name: name,
      size: size,
      kind: ItemKind.file,
      path: path,
      ownsFile: false,
    );
  }

  /// Puts a folder on the shelf as a zip of its contents. Files are stored
  /// uncompressed: zipping is for bundling, and the LAN is fast.
  Future<ShelfItem> addFolder(String path) async {
    final name = _baseName(path);
    final id = randomId();
    final zip = _itemPath(nodeId, id, '$name.zip');
    await File(zip).parent.create(recursive: true);
    final max = maxItemBytes; // so the closure does not capture `this`
    try {
      await Isolate.run(() => _zipFolder(path, zip, max));
    } catch (_) {
      _deleteItemDir(nodeId, id);
      rethrow;
    }
    final size = await File(zip).length();
    if (size > maxItemBytes) {
      _deleteItemDir(nodeId, id);
      throw ItemTooLargeException(size, maxItemBytes);
    }
    return _addLocal(
      id: id,
      name: name,
      size: size,
      kind: ItemKind.folder,
      path: zip,
      ownsFile: true,
    );
  }

  /// Puts in-memory bytes on the shelf, such as a pasted image.
  Future<ShelfItem> addBytes(List<int> bytes, String name) =>
      _addOwned(bytes, name, ItemKind.file, name);

  Future<ShelfItem> addText(String text) {
    final firstLine = text.trim().split('\n').first;
    final label = firstLine.length > 60
        ? '${firstLine.substring(0, 60)}…'
        : firstLine;
    return _addOwned(utf8.encode(text), label, ItemKind.text, 'text.txt');
  }

  Future<ShelfItem> _addOwned(
    List<int> bytes,
    String name,
    ItemKind kind,
    String fileName,
  ) async {
    _checkSize(bytes.length);
    final id = randomId();
    final file = File(_itemPath(nodeId, id, fileName));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    return _addLocal(
      id: id,
      name: name,
      size: bytes.length,
      kind: kind,
      path: file.path,
      ownsFile: true,
    );
  }

  ShelfItem _addLocal({
    String? id,
    required String name,
    required int size,
    required ItemKind kind,
    required String path,
    required bool ownsFile,
  }) {
    final item = ShelfItem(
      id: id ?? randomId(),
      originId: nodeId,
      originName: nodeName,
      name: name,
      size: size,
      mime: switch (kind) {
        ItemKind.text => 'text/plain; charset=utf-8',
        ItemKind.folder => 'application/zip',
        ItemKind.file => mimeFor(name),
      },
      kind: kind,
      expiresAt: DateTime.now().add(ttl),
      ttl: ttl,
      path: path,
      ownsFile: ownsFile,
    );
    _insert(item, ttl);
    _localChanges.add(null);
    return item;
  }

  void _checkSize(int size) {
    if (size > maxItemBytes) throw ItemTooLargeException(size, maxItemBytes);
  }

  /// Records a peer's item. Returns the new mirror, or null if it was already
  /// known, is over the size cap, or has an id that is not a plain token.
  ShelfItem? addRemote(String peerId, String peerName, RemoteItem r) {
    final key = itemKey(peerId, r.id);
    if (!_validId.hasMatch(r.id) ||
        _items.containsKey(key) ||
        r.size > maxItemBytes ||
        r.ttlMs <= 0) {
      return null;
    }
    final ttl = Duration(milliseconds: r.ttlMs);
    final item = ShelfItem(
      id: r.id,
      originId: peerId,
      originName: peerName,
      name: r.name,
      size: r.size,
      mime: r.mime,
      kind: r.kind,
      expiresAt: DateTime.now().add(ttl),
      ttl: ttl,
    );
    _insert(item, ttl);
    return item;
  }

  /// Where a mirror's bytes should be downloaded to.
  String downloadPath(ShelfItem item) =>
      _itemPath(item.originId, item.id, transferName(item));

  void setProgress(String key, double? progress) {
    final item = _items[key];
    if (item == null) return;
    item.progress = progress;
    _changes.add(null);
  }

  void markReady(String key, String path) {
    final item = _items[key];
    if (item == null) return;
    item
      ..path = path
      ..progress = null;
    _changes.add(null);
  }

  void remove(String key) {
    _timers.remove(key)?.cancel();
    final item = _items.remove(key);
    if (item == null) return;
    if (item.ownsFile) _deleteItemDir(item.originId, item.id);
    _changes.add(null);
    if (item.originId == nodeId) _localChanges.add(null);
  }

  void _insert(ShelfItem item, Duration ttl) {
    _items[item.key] = item;
    _timers[item.key] = Timer(ttl, () => _expire(item.key));
    _changes.add(null);
  }

  /// Expiry waits for a transfer that is still running, so a big download
  /// keeps its row and progress bar until it lands.
  void _expire(String key) {
    if (_items[key]?.progress != null) {
      _timers[key] = Timer(const Duration(seconds: 1), () => _expire(key));
    } else {
      remove(key);
    }
  }

  /// Ids become a directory name and part of a URL path, so a peer's ids
  /// must be plain tokens. Ours come from [randomId].
  static final _validId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

  String _itemDir(String originId, String id) => [
    dir.path,
    safeFileName(originId),
    safeFileName(id),
  ].join(Platform.pathSeparator);

  String _itemPath(String originId, String id, String fileName) =>
      '${_itemDir(originId, id)}${Platform.pathSeparator}${safeFileName(fileName)}';

  void _deleteItemDir(String originId, String id) {
    // An open download or upload can block deletion on Windows; the dir is
    // wiped on next launch anyway.
    Directory(
      _itemDir(originId, id),
    ).delete(recursive: true).then((_) {}, onError: (_) {});
  }

  static String _baseName(String path) => path
      .split(RegExp(r'[/\\]'))
      .lastWhere((s) => s.isNotEmpty, orElse: () => 'item');

  Future<void> dispose() async {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _items.clear();
    await _changes.close();
    await _localChanges.close();
  }
}
