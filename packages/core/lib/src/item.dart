import 'dart:math';

import 'package:characters/characters.dart';

/// `folder` items travel as a zip of the folder's contents.
enum ItemKind { file, text, folder }

/// Default time an item stays on the shelf.
const defaultTtl = Duration(seconds: 120);

/// Items at or under this size are copied as soon as they appear on a peer.
const defaultEagerCopyBytes = 25 * 1024 * 1024;

/// Wall-clock time an eager copy gets before it is abandoned, plus a second
/// per 256 KB of the item.
const defaultEagerDeadline = Duration(seconds: 30);

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
    this.ageAtArrival,
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

  /// For a mirror, how long ago its sender had put it up when this node
  /// first saw it (the list's `ageMs`); null for an own item, or from a
  /// sender too old to say. Something already minutes old on first sight
  /// came in while this device was asleep or away, not just now.
  final Duration? ageAtArrival;

  /// 0..1 while downloading, otherwise null.
  double? progress;

  /// Ids of the peers that have said they hold a complete copy of this item,
  /// so the sender can see it arrived. Only ever filled for own items, and
  /// with at most `ShelfStore.maxReceivedBy` of them.
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
    // Only ever sent for this node's own items, whose addedAt is the add.
    'ageMs': max(0, DateTime.now().difference(addedAt).inMilliseconds),
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

/// An entry from a peer's `GET /v1/items` list. [mime] goes through
/// [safeMime] here, so no peer-supplied type reaches anything unchecked.
class RemoteItem {
  RemoteItem({
    required this.id,
    required this.name,
    required this.size,
    required String mime,
    required this.kind,
    required this.ttlMs,
    this.ageMs,
  }) : mime = safeMime(mime);

  factory RemoteItem.fromJson(Map<String, dynamic> j) => RemoteItem(
    id: j['id'] as String,
    name: j['name'] as String,
    size: (j['size'] as num).toInt(),
    mime: j['mime'] is String ? j['mime'] as String : '',
    // Unknown kinds from newer peers degrade to plain files.
    kind: ItemKind.values.asNameMap()[j['kind']] ?? ItemKind.file,
    ttlMs: (j['ttlMs'] as num).toInt(),
    // Optional: older nodes leave it out. Nonsense reads as unknown.
    ageMs: switch (j['ageMs']) {
      final num a when a >= 0 && a < 1e12 => a.toInt(),
      _ => null,
    },
  );

  final String id;
  final String name;
  final int size;
  final String mime;
  final ItemKind kind;
  final int ttlMs;

  /// How long ago the sender put it up, in milliseconds; null when it
  /// doesn't say.
  final int? ageMs;
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

/// [raw] as a media type that is safe to put in a header: `type/subtype`
/// of token characters, lower-cased, with a `charset` parameter kept when
/// it is a plain token too and every other parameter dropped. Anything
/// else is `application/octet-stream`. A peer's `mime` ends up in the web
/// shelf's Content-Type, and dart:io's ContentType.parse lets CR and LF
/// through, so an unchecked one could add headers, or a whole second
/// response, to what a phone receives.
String safeMime(String raw) {
  final [type, ...params] = raw.split(';');
  final t = type.trim().toLowerCase();
  if (!_mimeType.hasMatch(t)) return 'application/octet-stream';
  for (final p in params) {
    final m = _charset.firstMatch(p.trim());
    if (m != null) return '$t; charset=${m[1]!.toLowerCase()}';
  }
  return t;
}

final _mimeType = RegExp(
  r'^[a-z0-9][a-z0-9.+_-]{0,63}/[a-z0-9][a-z0-9.+_-]{0,127}$',
);
final _charset = RegExp(
  r'^charset=([A-Za-z0-9._:-]{1,40})$',
  caseSensitive: false,
);

String mimeFor(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return 'application/octet-stream';
  return _mimes[name.substring(dot + 1).toLowerCase()] ??
      'application/octet-stream';
}

/// [name] as one line that reads as what it is ([safeLabel]), trimmed, and
/// cut to [max] UTF-16 units with an ellipsis before the extension, which
/// stays. The cut falls between whole characters: no half emoji or flag.
String cleanName(String name, {required int max}) {
  final s = safeLabel(name).trim();
  if (s.length <= max) return s;
  final dot = s.lastIndexOf('.');
  final ext = dot > 0 && s.length - dot <= 16 ? s.substring(dot) : '';
  final room = max - 1 - ext.length;
  final head = StringBuffer();
  var used = 0;
  for (final c in s.characters) {
    if (used + c.length > room) break;
    head.write(c);
    used += c.length;
  }
  return '$head…$ext';
}

/// Makes a peer-supplied name read as what it is, with no character that
/// changes how the text around it is shown while unseen itself. A
/// right-to-left override makes `invoice\u202Efdp.exe` read as "invoice"
/// then "exe.pdf" on every shelf and in Finder and Explorer, and a double
/// click runs it; a newline in `invoice.pdf\n.exe` leaves a one-line row
/// showing `invoice.pdf`. Those, and every C0 and C1 control, the bidi
/// embeddings, overrides and isolates, and the line and paragraph
/// separators, become `_`, so the place shows.
///
/// The other invisible marks go without a trace: the bidi marks (LRM, RLM,
/// ALM), zero-width space, word joiner, invisible operators and BOM. They
/// cannot turn a run of Latin text around, and are everyday in Hebrew and
/// Arabic names and Thai text, which must not sprout underscores. The
/// joiners U+200C and U+200D stay: Persian and Hindi words and emoji
/// sequences need them.
///
/// The one helper for this, for a name shown anywhere as well as saved.
String safeLabel(String name) =>
    name.replaceAll(_hiding, '_').replaceAll(_invisible, '');

/// Whether [name] has nothing to show once what [safeLabel] replaces or
/// drops is gone: no name at all, rather than one of underscores.
bool isBlankLabel(String name) =>
    name.replaceAll(_hiding, '').replaceAll(_invisible, '').trim().isEmpty;

final _hiding = RegExp(r'[\x00-\x1f\x7f-\x9f\u2028-\u202e\u2066-\u2069]');
final _invisible = RegExp(
  r'[\u061c\u200b\u200e\u200f\u2060-\u2064\u206a-\u206f\ufeff]',
);

/// Makes a peer-supplied name safe to use as a single path segment on every
/// platform plop runs on, and to show: [safeLabel] first, which also
/// takes out the control characters no file system wants. Dotfiles stay
/// dotfiles (`.env` must not arrive as `env`); with the separators
/// replaced, only the bare `.` and `..` names need refusing. Windows also
/// drops trailing dots and spaces, so `notes.` would land on `notes`, and
/// reserves its device names (`CON`, `NUL.txt`, `com1.log`…), which get a
/// `_` after the stem.
String safeFileName(String name) {
  var cleaned = safeLabel(name)
      .replaceAll(RegExp(r'[/\\:*?"<>|]'), '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (cleaned.isEmpty) return 'file';
  if (cleaned.length > 120) {
    // The whole characters at the end that fit: no half emoji or flag at
    // the start of the name (see `_head` in shelf_store.dart).
    var start = cleaned.length;
    for (final c in cleaned.characters.toList().reversed) {
      if (cleaned.length - start + c.length > 120) break;
      start -= c.length;
    }
    cleaned = cleaned.substring(start);
  }
  return cleaned.replaceFirstMapped(_reserved, (m) => '${m[1]}_${m[2]}');
}

/// Windows device names, with any extension, in any case.
final _reserved = RegExp(
  r'^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])(\.|$)',
  caseSensitive: false,
);
