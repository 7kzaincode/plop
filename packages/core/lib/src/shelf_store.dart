import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'item.dart';

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
  final Duration ttl;
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

  /// Puts a file on the shelf. The file is served in place, not copied.
  Future<ShelfItem> addFile(String path, {String? name}) async {
    final size = await File(path).length();
    _checkSize(size);
    name ??= path.split(Platform.pathSeparator).last;
    return _addLocal(
      name: name,
      size: size,
      kind: ItemKind.file,
      path: path,
      ownsFile: false,
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
      mime: kind == ItemKind.text ? 'text/plain; charset=utf-8' : mimeFor(name),
      kind: kind,
      expiresAt: DateTime.now().add(ttl),
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
  /// known or is over the size cap.
  ShelfItem? addRemote(String peerId, String peerName, RemoteItem r) {
    final key = itemKey(peerId, r.id);
    if (_items.containsKey(key) || r.size > maxItemBytes || r.ttlMs <= 0) {
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
    );
    _insert(item, ttl);
    return item;
  }

  /// Where a mirror's bytes should be downloaded to.
  String downloadPath(ShelfItem item) => _itemPath(
    item.originId,
    item.id,
    item.kind == ItemKind.text ? 'text.txt' : item.name,
  );

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
    _timers[item.key] = Timer(ttl, () => remove(item.key));
    _changes.add(null);
  }

  String _itemDir(String originId, String id) =>
      [dir.path, safeFileName(originId), id].join(Platform.pathSeparator);

  String _itemPath(String originId, String id, String fileName) =>
      '${_itemDir(originId, id)}${Platform.pathSeparator}${safeFileName(fileName)}';

  void _deleteItemDir(String originId, String id) {
    // An open download or upload can block deletion on Windows; the dir is
    // wiped on next launch anyway.
    Directory(
      _itemDir(originId, id),
    ).delete(recursive: true).then((_) {}, onError: (_) {});
  }

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
