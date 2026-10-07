import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:characters/characters.dart';

import 'item.dart';

/// Unpacks a folder item's zip into [outDir]. Only plain files and folders
/// are written: symlinks are skipped (plop never sends them, and a chain of
/// them can steer later entries outside [outDir]), as are names with `..`.
/// Each name segment goes through [safeFileName], as a single file's name
/// does: a Mac's `Meeting 10:3.txt` is not a valid name on Windows, where
/// the colon would address an NTFS stream rather than fail.
/// Of the sender's permissions only the executable bit is kept, so a script
/// or binary still runs; the rest is the receiver's business.
///
/// plop only ever stores entries, so a compressed one comes from a hostile
/// or foreign peer and is refused with a [FormatException], as is an
/// encrypted one, which would be read whole to decrypt it: the archive
/// package inflates into memory whole, and a 1 MB deflate can unpack to
/// gigabytes. Stored entries can only add up to more than the zip itself
/// when their headers overlap, another bomb, so the output is bounded by
/// the zip's own size. A failure removes [outDir] if this call created it.
///
/// The central directory is read and vetted here rather than through
/// [ZipDecoder], which reads every entry flagged as a Unix symlink while
/// decoding, to learn its target: a deflated "link" would be inflated into
/// memory before any check here ran. Nothing is read until its header has
/// passed. An entry named twice is written twice, the second numbered.
Future<void> extractFolder(String zipPath, String outDir) => Isolate.run(
  () async {
    final target = Directory(outDir);
    // Not `target.existsSync()`, which is false for a file at [outDir] too:
    // the cleanup below deletes whatever is at the path, so `fresh` must
    // mean nothing was there.
    final fresh =
        FileSystemEntity.typeSync(outDir) == FileSystemEntityType.notFound;
    await target.create(recursive: true);
    final budget = File(zipPath).lengthSync();
    var written = 0;
    final places = _Places(outDir);
    final input = InputFileStream(zipPath);
    try {
      final dir = ZipDirectory()..read(input);
      for (final h in dir.fileHeaders) {
        final f = h.file!;
        // plop never encrypts either, and the archive package would decrypt
        // with no password, reading the whole entry into memory and doing
        // big-integer sums on every byte of it. Bit 0, in either header.
        if (h.generalPurposeBitFlag & 1 != 0 || f.flags & 1 != 0) {
          throw const FormatException('folder zip is encrypted');
        }
        // Before anything is skipped, so no compressed entry gets past: a
        // link or a `..` name is still a zip plop did not make. Both
        // headers, since the local one maps a method it does not know to
        // "stored" and would copy the packed bytes out as they are.
        if (f.compressionMethod != CompressionType.none ||
            h.compressionMethod != ZipFile.zipCompressionStore) {
          throw const FormatException('folder zip is compressed');
        }
        final mode = h.externalFileAttributes >> 16;
        final isLink = h.versionMadeBy >> 8 == 3 && mode & 0xf000 == 0xa000;
        final parts = h.filename.split(RegExp(r'[/\\]'))
          ..removeWhere((s) => s.isEmpty || s == '.');
        if (isLink || parts.isEmpty || parts.contains('..')) continue;
        final isDir = h.filename.endsWith('/') || h.filename.endsWith('\\');
        final path = places.of(parts, isDir: isDir);
        if (isDir) {
          await Directory(path).create(recursive: true);
          continue;
        }
        final out = _BoundedOutput(path, budget - written);
        try {
          f.decompress(out); // stored: copied through in 1 MB writes
        } finally {
          written += out.length;
          await out.close();
        }
        if (mode & 0x49 != 0 && (Platform.isMacOS || Platform.isLinux)) {
          _setExecutable(path);
        }
      }
    } catch (_) {
      if (fresh) await target.delete(recursive: true).catchError((_) => target);
      rethrow;
    } finally {
      await input.close();
    }
  },
);

/// Where each entry of a zip lands under its target folder. Sanitising can
/// make two names one: `a:b.txt` and `a?b.txt` both become `a_b.txt`, and
/// a file `notes:` lands where a folder `notes_` goes, which fails the
/// whole unpack. The second to claim a path gets ` (1)`, ` (2)`… before
/// its extension, while entries under one source folder keep landing in
/// the same place, numbered or not.
class _Places {
  _Places(this.root);

  final String root;
  final _bySource = <String, String>{}; // source path -> where it landed
  final _taken = <String>{};

  String of(List<String> parts, {required bool isDir}) {
    var source = '';
    var path = root;
    for (final (i, part) in parts.indexed) {
      source = i == 0 ? part : '$source/$part';
      final name = safeFileName(part);
      // Only a folder is looked up by source, so its contents follow it.
      // A file is nothing's parent, and a zip may well name one twice: the
      // second is then a second file, not the first one again.
      path = isDir || i < parts.length - 1
          ? _bySource[source] ??= _free(path, name, isDir: true)
          : _free(path, name, isDir: false);
    }
    return path;
  }

  String _free(String parent, String name, {required bool isDir}) {
    var path = '$parent${Platform.pathSeparator}$name';
    for (var n = 1; !_taken.add(_key(path)); n++) {
      path = '$parent${Platform.pathSeparator}${_numbered(name, n, isDir)}';
    }
    return path;
  }

  /// macOS and Windows file systems ignore case, so `A.txt` and `a.txt`
  /// from a Linux sender would otherwise land on each other.
  static String _key(String path) =>
      Platform.isMacOS || Platform.isWindows ? path.toLowerCase() : path;

  /// `name (n)`, or `stem (n).ext` for a file with an extension. A dotfile
  /// has none: `.env (1)`.
  static String _numbered(String name, int n, bool isDir) {
    final dot = isDir ? -1 : name.lastIndexOf('.');
    return dot <= 0
        ? '$name ($n)'
        : '${name.substring(0, dot)} ($n)${name.substring(dot)}';
  }
}

/// An [OutputFileStream] that throws rather than grow past [limit] bytes.
/// Creates parent folders, as [OutputFileStream] itself does.
class _BoundedOutput extends OutputFileStream {
  _BoundedOutput(String path, this.limit)
    : super.withFileHandle(FileHandle(path, mode: FileAccess.write));

  final int limit;

  @override
  void writeByte(int value) {
    _fit(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _fit(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  void _fit(int n) {
    if (length + n > limit) {
      throw const FormatException('folder zip unpacks to more than its size');
    }
  }
}

/// Makes [path] executable for whoever can already read it, as `chmod +x`
/// would under the receiver's umask. dart:io cannot change permissions, so
/// this calls libc; not for Windows, which has no executable bit.
void _setExecutable(String path) {
  final mode = File(path).statSync().mode;
  final bytes = utf8.encode(path);
  final cPath = _malloc(bytes.length + 1);
  cPath.asTypedList(bytes.length + 1)
    ..setAll(0, bytes)
    ..[bytes.length] = 0;
  try {
    _chmod(cPath, (mode | (mode & 0x124) >> 2) & 0xfff);
  } finally {
    _free(cPath);
  }
}

final _libc = DynamicLibrary.process();
final _chmod = _libc
    .lookupFunction<
      Int32 Function(Pointer<Uint8>, Uint32),
      int Function(Pointer<Uint8>, int)
    >('chmod');
final _malloc = _libc
    .lookupFunction<
      Pointer<Uint8> Function(Size),
      Pointer<Uint8> Function(int)
    >('malloc');
final _free = _libc
    .lookupFunction<
      Void Function(Pointer<Uint8>),
      void Function(Pointer<Uint8>)
    >('free');

/// Writes the contents of [dir] to [zip]. Entries are stored with
/// [CompressionType.none], which the archive package streams; it would
/// deflate anything else into memory whole. Links are never followed out of
/// the folder: one whose target is inside it goes in as a copy of the target
/// (a framework's `Versions/Current -> A`; on Windows, a cloud placeholder,
/// which is listed as a link to itself), one that leads outside is skipped.
Future<void> _zipFolder(String dir, String zip, int maxBytes) async {
  // Resolving can fail on some Windows volumes (folder mounts, WebDAV); a
  // plain folder then stands for itself, while a link that cannot be
  // resolved is still skipped by the caller.
  String realOf(FileSystemEntity e) {
    try {
      return e.resolveSymbolicLinksSync();
    } on FileSystemException {
      if (e is Link) rethrow;
      return e.path;
    }
  }

  final root = realOf(Directory(dir));
  final entries = <(String, FileStat)>[];
  // [above] holds the real paths of the folders being walked, to break loops.
  void walk(String path, Set<String> above) {
    for (final e in Directory(path).listSync(followLinks: false)) {
      final stat = e.statSync(); // a link's target
      if (e is! Link && stat.type == FileSystemEntityType.file) {
        entries.add((e.path, stat));
        continue;
      }
      final String real;
      try {
        real = realOf(e);
      } on FileSystemException {
        continue; // dangling, or gone since it was listed
      }
      if (e is Link &&
          real != root &&
          !real.startsWith('$root${Platform.pathSeparator}')) {
        continue; // leads outside the folder
      }
      if (stat.type == FileSystemEntityType.file) {
        entries.add((e.path, stat));
      } else if (stat.type == FileSystemEntityType.directory) {
        if (!above.add(real)) continue; // a loop
        entries.add((e.path, stat));
        walk(e.path, above);
        above.remove(real);
      }
    }
  }

  walk(dir, {root});
  // Refuse before writing anything rather than after copying it all.
  final total = entries
      .where((e) => e.$2.type == FileSystemEntityType.file)
      .fold(0, (n, e) => n + e.$2.size);
  if (total > maxBytes) throw ItemTooLargeException(total, maxBytes);
  final enc = ZipFileEncoder()..create(zip);
  for (final (path, stat) in entries) {
    final name = path
        .substring(dir.length)
        .replaceFirst(RegExp(r'^[/\\]+'), '');
    final f = stat.type == FileSystemEntityType.directory
        ? ArchiveFile.directory(name)
        : ArchiveFile.stream(name, InputFileStream(path));
    // Folder entries too: an empty "deflated" entry is invalid to unzip.
    // Only the executable bit travels: 0755 for folders and anything the
    // sender can run, 0644 otherwise. Other unzippers apply these bits
    // verbatim, so a Windows sender's 0666/0777 must not leak through.
    final isDir = stat.type == FileSystemEntityType.directory;
    final mode =
        (stat.mode & 0xf000) | (isDir || stat.mode & 0x49 != 0 ? 0x1ed : 0x1a4);
    enc.addArchiveFile(
      f
        ..mode = mode
        ..lastModTime = stat.modified.millisecondsSinceEpoch ~/ 1000
        ..compression = CompressionType.none,
    );
  }
  await enc.close();
}

/// The whole characters (grapheme clusters) at the start of [s] that fit
/// in [n] UTF-16 units. A cut inside one leaves a broken glyph on every
/// peer and in a saved file's name: half a surrogate pair turns into
/// U+FFFD, half a flag is a boxed letter, and a family emoji cut at a
/// joiner loses a member.
String _head(String s, int n) {
  if (s.length <= n) return s;
  var end = 0;
  for (final c in s.characters) {
    if (end + c.length > n) break;
    end += c.length;
  }
  return s.substring(0, end);
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

  /// First sight of mirrors that left the shelf before their time, by key,
  /// with the time they had. A peer that misses three polls, or whose mDNS
  /// record flickers while a phone sleeps, takes its uncopied items with it
  /// and brings them back a moment later; without this they would come back
  /// as the newest. Pruned of expired entries whenever one is added.
  final _firstSeen = <String, ({DateTime addedAt, DateTime expiresAt})>{};
  final _changes = StreamController<void>.broadcast();
  final _localChanges = StreamController<void>.broadcast();

  /// Fires on any change, including download progress.
  Stream<void> get changes => _changes.stream;

  /// Fires when this node's own items are added or removed.
  Stream<void> get localChanges => _localChanges.stream;

  /// Newest first, by [ShelfItem.addedAt]. Files dropped in one gesture can
  /// tie to the microsecond and `sort` is not stable, so insertion order,
  /// which `_items` keeps, breaks ties.
  List<ShelfItem> get items {
    final indexed = _items.values.indexed.toList()
      ..sort((a, b) {
        final byTime = b.$2.addedAt.compareTo(a.$2.addedAt);
        return byTime != 0 ? byTime : b.$1.compareTo(a.$1);
      });
    return [for (final (_, item) in indexed) item];
  }

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
    final file = File(path);
    final size = await file.length();
    _checkSize(size);
    name ??= _baseName(path);
    return _addLocal(
      name: name,
      size: size,
      kind: ItemKind.file,
      path: path,
      ownsFile: false,
      // From stat(), as the check against it is, so the two agree to the
      // same precision.
      sourceModified: (await file.stat()).modified,
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

  /// Streams [body] to disk as an owned file named [name], so an upload
  /// never has to fit in memory. The cap is [maxItemBytes], or [maxBytes]
  /// when that is lower. An [expectedSize] over it is refused before a
  /// byte is read, a body that grows past it is cut off where it does
  /// (both [ItemTooLargeException]), and one that ends short of
  /// [expectedSize] is dropped with a [FormatException]: a connection that
  /// broke mid-upload must not leave half a file on the shelf. An error
  /// from [body] (a timeout, say) drops it as well.
  Future<ShelfItem> addStream(
    Stream<List<int>> body,
    String name, {
    int? expectedSize,
    int? maxBytes,
  }) async {
    final cap = min(maxBytes ?? maxItemBytes, maxItemBytes);
    if (expectedSize != null && expectedSize > cap) {
      throw ItemTooLargeException(expectedSize, cap);
    }
    final id = randomId();
    final file = File(_itemPath(nodeId, id, name));
    await file.parent.create(recursive: true);
    final out = await file.open(mode: FileMode.write);
    var size = 0;
    try {
      // Throwing out of `await for` cancels the body's subscription, which
      // is how the sender gets cut off.
      await for (final chunk in body) {
        size += chunk.length;
        if (size > cap) throw ItemTooLargeException(size, cap);
        await out.writeFrom(chunk);
      }
      if (expectedSize != null && size != expectedSize) {
        throw FormatException('upload ended at $size of $expectedSize bytes');
      }
    } catch (_) {
      await out.close().catchError((_) {});
      _deleteItemDir(nodeId, id);
      rethrow;
    }
    await out.close();
    return _addLocal(
      id: id,
      name: name,
      size: size,
      kind: ItemKind.file,
      path: file.path,
      ownsFile: true,
    );
  }

  Future<ShelfItem> addText(String text) {
    // `\r` too: a Windows line ends in `\r\n`, and a `\r` left on the
    // label would show as `_` on every peer.
    final firstLine = text.trim().split(RegExp('[\r\n]')).first;
    final label = firstLine.length > 60
        ? '${_head(firstLine, 60)}…'
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
    DateTime? sourceModified,
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
      sourceModified: sourceModified,
    );
    _insert(item, ttl);
    _localChanges.add(null);
    return item;
  }

  void _checkSize(int size) {
    if (size > maxItemBytes) throw ItemTooLargeException(size, maxItemBytes);
  }

  /// Longest lifetime accepted from a peer; the app itself offers 30 s–1 h.
  static const maxRemoteTtl = Duration(hours: 24);

  /// Longer peer-supplied names are cut; on disk they are already.
  static const maxNameLength = 255;

  /// Records a peer's item. Returns the new mirror, or null if it was already
  /// known, has a size outside 0..cap, or an id that is not a plain token.
  /// An odd but honest peer still gets its item shown: a huge `ttlMs` is
  /// clamped and a long name cut rather than refused. Invisible formatting
  /// characters in the name are shown as `_` ([safeLabel]), as saving it
  /// would write them, so a row cannot pass off `fdp.exe` as `exe.pdf`.
  ShelfItem? addRemote(String peerId, String peerName, RemoteItem r) {
    final key = itemKey(peerId, r.id);
    if (!isValidId(r.id) ||
        _items.containsKey(key) ||
        r.size < 0 ||
        r.size > maxItemBytes ||
        r.ttlMs <= 0) {
      return null;
    }
    // After toInt(): 1e300 saturates to 2^63-1, which Duration wraps negative.
    final ttl = Duration(
      milliseconds: min(r.ttlMs, maxRemoteTtl.inMilliseconds),
    );
    final name = _head(safeLabel(r.name), maxNameLength);
    final now = DateTime.now();
    final seen = _firstSeen.remove(key);
    final item = ShelfItem(
      id: r.id,
      originId: peerId,
      originName: peerName,
      name: name,
      size: r.size,
      mime: r.mime,
      kind: r.kind,
      expiresAt: now.add(ttl),
      ttl: ttl,
      addedAt: seen != null && seen.expiresAt.isAfter(now)
          ? seen.addedAt
          : null,
      ageAtArrival: r.ageMs == null ? null : Duration(milliseconds: r.ageMs!),
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

  /// Most peers an own item's [ShelfItem.receivedBy] records. A real shelf
  /// has a handful; a peer making up ids must not grow it without end, and
  /// under such a flood the list may miss a real peer, which is all.
  static const maxReceivedBy = 64;

  /// Records that [peerId] holds a complete copy of an own item. Fires a
  /// change only when that is news.
  void markReceived(String key, String peerId) {
    final item = _items[key];
    if (item == null || item.receivedBy.length >= maxReceivedBy) return;
    if (item.receivedBy.add(peerId)) _changes.add(null);
  }

  /// Whether an item is still what was put on the shelf. A file served in
  /// place can be deleted or rewritten after it was dropped; listing it
  /// then leaves every peer a row it can never fetch, and handing it out
  /// gives a phone something other than what was shared, so instead it
  /// leaves the shelf (false), which nudges peers to drop theirs. For /v1
  /// and the web shelf alike.
  ///
  /// Asynchronous because this runs on every poll from every peer, and a
  /// stat of a file on an unmounted share or a cloud placeholder can hang
  /// for seconds; a synchronous one would stall the whole isolate with it.
  ///
  /// A check still running is shared, so a hung stat is joined by every
  /// poll from every peer rather than one more each time; callers bound
  /// their wait ([NodeServer.statBudget]).
  Future<bool> stillThere(ShelfItem i) {
    if (i.ownsFile || i.path == null) return Future.value(true);
    // The callback must not return the removed future: whenComplete would
    // wait on it, and it is the future being completed.
    return _checks[i.key] ??= _check(i).whenComplete(() {
      _checks.remove(i.key);
    });
  }

  final _checks = <String, Future<bool>>{};

  Future<bool> _check(ShelfItem i) async {
    final st = await File(i.path!).stat();
    // Size alone misses a rewrite that keeps it, so the modification time
    // counts too; a store that never recorded one only has the size.
    if (st.type != FileSystemEntityType.notFound &&
        st.size == i.size &&
        (i.sourceModified == null || st.modified == i.sourceModified)) {
      return true;
    }
    remove(i.key);
    return false;
  }

  void remove(String key) {
    _timers.remove(key)?.cancel();
    final item = _items.remove(key);
    if (item == null) return;
    if (item.ownsFile) _deleteItemDir(item.originId, item.id);
    if (item.originId != nodeId) _rememberFirstSeen(item);
    _changes.add(null);
    if (item.originId == nodeId) _localChanges.add(null);
  }

  void _rememberFirstSeen(ShelfItem mirror) {
    final now = DateTime.now();
    _firstSeen.removeWhere((_, v) => !v.expiresAt.isAfter(now));
    if (mirror.expiresAt.isAfter(now)) {
      _firstSeen[mirror.key] = (
        addedAt: mirror.addedAt,
        expiresAt: mirror.expiresAt,
      );
    }
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
    _firstSeen.clear();
    await _changes.close();
    await _localChanges.close();
  }
}
