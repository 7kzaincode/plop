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
    this.path,
    this.ownsFile = true,
  });

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

  /// 0..1 while downloading, otherwise null.
  double? progress;

  String get key => itemKey(originId, id);
  bool get isReady => path != null;

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

/// Makes a peer-supplied name safe to use as a single path segment.
String safeFileName(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'^\.+'), '')
      .trim();
  if (cleaned.isEmpty) return 'file';
  return cleaned.length > 120
      ? cleaned.substring(cleaned.length - 120)
      : cleaned;
}
