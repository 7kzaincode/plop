import 'dart:math';

/// `folder` items travel as a zip of the folder's contents.
enum ItemKind { file, text, folder }

/// Default time an item stays on the shelf.
const defaultTtl = Duration(seconds: 120);

/// Items at or under this size are copied as soon as they appear on a peer.
const defaultEagerCopyBytes = 25 * 1024 * 1024;

/// Hard per-item cap. Large items are only ever downloaded on request, so
/// this just guards against absurd sizes.
const defaultMaxItemBytes = 100 * 1024 * 1024 * 1024;

/// An item on this node's shelf: either one it originated or a mirror of a
/// peer's item.
class ShelfItem {
  ShelfItem({
    required this.id,
    required this.originId,
    required this.originName,
    required this.name,
    required this.size,
    required this.mime,
    required this.kind,
    required this.expiresAt,
    required this.ttl,
    DateTime? addedAt,
    this.path,
    this.ownsFile = true,
    this.sourceModified,
  }) : addedAt = addedAt ?? expiresAt.subtract(ttl);

  final String id;
  final String originId;
  final String originName;
  final String name;
  final int size;
  final String mime;
  final ItemKind kind;
  final DateTime expiresAt;

  /// Total lifetime as this node first saw it, for drawing a countdown.
  final Duration ttl;

  /// Where the bytes live on this device. Null until a mirror is downloaded.
  String? path;

  /// Whether expiry should delete [path]. False for a local file the user
  /// picked, which is served in place rather than copied.
  final bool ownsFile;

  /// Modification time of a file served in place, as it was when added.
  /// With the size, this is how a rewrite of that file is noticed; null
  /// for anything the store owns.
  final DateTime? sourceModified;

  /// 0..1 while downloading, otherwise null.
  double? progress;

  /// Ids of the peers that have said they hold a complete copy of this item,
  /// so the sender can see it arrived. Only ever filled for own items.
  final receivedBy = <String>{};

  String get key => itemKey(originId, id);
  bool get isReady => path != null;

  /// When this node first saw the item: the add for its own, first sight of
  /// a mirror. Shelf order, which [expiresAt] is not once lifetimes differ.
  /// The start of [ttl] unless given: a mirror that left the shelf early
  /// and came back is handed its first date, so it keeps its place.
  final DateTime addedAt;

  Duration get remaining {
    final r = expiresAt.difference(DateTime.now());
    return r.isNegative ? Duration.zero : r;
  }

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'size': size,
    'mime': mime,
    'kind': kind.name,
    'ttlMs': remaining.inMilliseconds,
  };
}

String itemKey(String originId, String id) => '$originId/$id';

/// Whether a peer-supplied id, of a node or of an item, is a plain token:
/// 1–64 characters from `A-Z a-z 0-9 _ -`. Ids become directory names,
/// parts of URL paths and keys in per-peer maps, so anything else is
/// refused. Ours come from [randomId].
bool isValidId(String id) => _validId.hasMatch(id);

final _validId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// File name for an item's bytes on disk.
String transferName(ShelfItem item) => switch (item.kind) {
  ItemKind.text => 'text.txt',
  ItemKind.folder => '${item.name}.zip',
  ItemKind.file => item.name,
};

/// An entry from a peer's `GET /v1/items` list.
class RemoteItem {
  RemoteItem({
    required this.id,
    required this.name,
    required this.size,
    required this.mime,
    required this.kind,
    required this.ttlMs,
  });

  factory RemoteItem.fromJson(Map<String, dynamic> j) => RemoteItem(
    id: j['id'] as String,
    name: j['name'] as String,
    size: (j['size'] as num).toInt(),
    mime: j['mime'] as String? ?? 'application/octet-stream',
    // Unknown kinds from newer peers degrade to plain files.
    kind: ItemKind.values.asNameMap()[j['kind']] ?? ItemKind.file,
    ttlMs: (j['ttlMs'] as num).toInt(),
  );

  final String id;
  final String name;
  final int size;
  final String mime;
  final ItemKind kind;
  final int ttlMs;
}

final _rng = Random.secure();

String randomId([int bytes = 8]) => List.generate(
  bytes,
  (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

const _mimes = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'avif': 'image/avif',
  'heic': 'image/heic',
  'svg': 'image/svg+xml',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'json': 'application/json',
  'csv': 'text/csv',
  'html': 'text/html',
  'zip': 'application/zip',
  'mp4': 'video/mp4',
  'mov': 'video/quicktime',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'wav': 'audio/wav',
};

String mimeFor(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return 'application/octet-stream';
  return _mimes[name.substring(dot + 1).toLowerCase()] ??
      'application/octet-stream';
}

/// Makes a peer-supplied name safe to use as a single path segment. Dotfiles
/// stay dotfiles (`.env` must not arrive as `env`); with the separators
/// replaced, only the bare `.` and `..` names need refusing.
String safeFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_').trim();
  if (RegExp(r'^\.*$').hasMatch(cleaned)) return 'file';
  return cleaned.length > 120
      ? cleaned.substring(cleaned.length - 120)
      : cleaned;
}
