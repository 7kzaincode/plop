import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:plop_core/plop_core.dart';

/// File categories, each with its own glyph on the plop "bucket" tile.
enum FileCategory {
  image,
  video,
  audio,
  document,
  pdf,
  code,
  spreadsheet,
  presentation,
  archive,
  model3d,
  project,
  data,
  executable,
  terminal,
  font,
  note,
  web,
  folder,
  unknown,
}

const _extensions = <FileCategory, List<String>>{
  FileCategory.image: [
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'tif', //
    'tiff', 'svg', 'ico', 'raw', 'dng', 'avif',
  ],
  FileCategory.video: ['mp4', 'mov', 'avi', 'mkv', 'webm', 'm4v', 'wmv'],
  FileCategory.audio: ['mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg', 'aiff'],
  FileCategory.document: ['txt', 'doc', 'docx', 'rtf', 'pages', 'odt', 'log'],
  FileCategory.pdf: ['pdf'],
  FileCategory.code: [
    'py', 'js', 'ts', 'jsx', 'tsx', 'c', 'cc', 'cpp', 'h', 'hpp', 'java', //
    'kt', 'swift', 'go', 'rs', 'rb', 'php', 'html', 'css', 'scss', 'dart',
    'cs', 'lua', 'vue', 'svelte', 'm', 'mm',
  ],
  FileCategory.spreadsheet: ['xlsx', 'xls', 'csv', 'tsv', 'numbers', 'ods'],
  FileCategory.presentation: ['pptx', 'ppt', 'key', 'odp'],
  FileCategory.archive: ['zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz'],
  FileCategory.model3d: [
    'stl',
    'obj',
    'fbx',
    'gltf',
    'glb',
    'blend',
    '3mf',
    'step',
    'stp',
    'usdz',
  ],
  FileCategory.project: ['psd', 'fig', 'sketch', 'ai', 'xd', 'aep', 'prproj'],
  FileCategory.data: [
    'json',
    'db',
    'sql',
    'sqlite',
    'xml',
    'yaml',
    'yml',
    'parquet',
    'toml',
  ],
  FileCategory.executable: [
    'exe',
    'app',
    'dmg',
    'msi',
    'apk',
    'ipa',
    'deb',
    'pkg',
    'rpm',
  ],
  FileCategory.terminal: ['sh', 'bash', 'zsh', 'bat', 'cmd', 'ps1', 'command'],
  FileCategory.font: ['ttf', 'otf', 'woff', 'woff2'],
  FileCategory.note: ['md', 'markdown', 'note'],
  FileCategory.web: ['url', 'webloc', 'website'],
};

final _byExtension = {
  for (final e in _extensions.entries)
    for (final ext in e.value) ext: e.key,
};

FileCategory categoryOf(ShelfItem item) {
  switch (item.kind) {
    case ItemKind.text:
      return FileCategory.document;
    case ItemKind.folder:
      return FileCategory.folder;
    case ItemKind.file:
      final dot = item.name.lastIndexOf('.');
      if (dot >= 0) {
        final cat = _byExtension[item.name.substring(dot + 1).toLowerCase()];
        if (cat != null) return cat;
      }
      if (item.mime.startsWith('image/')) return FileCategory.image;
      if (item.mime.startsWith('video/')) return FileCategory.video;
      if (item.mime.startsWith('audio/')) return FileCategory.audio;
      return FileCategory.unknown;
  }
}

/// A white tile shaped like the plop logo's bucket, with a black glyph.
class TypeIcon extends StatelessWidget {
  const TypeIcon(this.category, {super.key, this.size = 32});

  final FileCategory category;
  final double size;

  @override
  Widget build(BuildContext context) {
    final glyph = size * 0.52;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: const _BucketPainter(),
        child: Padding(
          // Glyph sits a little above centre, clear of the curved bottom.
          padding: EdgeInsets.only(bottom: size * 0.12),
          child: Center(child: _glyph(glyph)),
        ),
      ),
    );
  }

  Widget _glyph(double s) => switch (_glyphOf(category)) {
    _Icon(:final data) => Icon(data, size: s, color: _ink),
    _Label(:final text, :final scale) => Text(
      text,
      style: _labelStyle(s * scale),
    ),
    _Zipper() => CustomPaint(
      size: Size.square(s),
      painter: const _ZipperPainter(_ink),
    ),
    _Dot() => Container(
      width: s * 0.3,
      height: s * 0.3,
      decoration: const BoxDecoration(color: _ink, shape: BoxShape.circle),
    ),
  };
}

const _ink = Color(0xFF0A0A0A);

TextStyle _labelStyle(double size) => TextStyle(
  fontFamily: 'Geist',
  fontWeight: FontWeight.w500,
  fontSize: size,
  height: 1,
  color: _ink,
  letterSpacing: 0,
);

/// What sits on a category's tile: a Material glyph, a word, or a drawing.
sealed class _Glyph {
  const _Glyph();
}

class _Icon extends _Glyph {
  const _Icon(this.data);
  final IconData data;
}

class _Label extends _Glyph {
  const _Label(this.text, this.scale);
  final String text;
  final double scale;
}

class _Zipper extends _Glyph {
  const _Zipper();
}

class _Dot extends _Glyph {
  const _Dot();
}

_Glyph _glyphOf(FileCategory category) => switch (category) {
  FileCategory.image => const _Icon(Icons.landscape_rounded),
  FileCategory.video => const _Icon(Icons.play_arrow_rounded),
  FileCategory.audio => const _Icon(Icons.music_note_rounded),
  FileCategory.document => const _Icon(Icons.notes_rounded),
  FileCategory.pdf => const _Label('PDF', 0.62),
  FileCategory.code => const _Icon(Icons.code_rounded),
  FileCategory.spreadsheet => const _Icon(Icons.grid_view_rounded),
  FileCategory.presentation => const _Icon(Icons.pie_chart_rounded),
  FileCategory.archive => const _Zipper(),
  FileCategory.model3d => const _Icon(Icons.view_in_ar_rounded),
  FileCategory.project => const _Icon(Icons.layers_rounded),
  FileCategory.data => const _Icon(Icons.storage_rounded),
  FileCategory.executable => const _Icon(Icons.settings_rounded),
  FileCategory.terminal => const _Icon(Icons.terminal_rounded),
  FileCategory.font => const _Label('Aa', 0.72),
  FileCategory.note => const _Icon(Icons.sticky_note_2_rounded),
  FileCategory.web => const _Icon(Icons.language_rounded),
  FileCategory.folder => const _Icon(Icons.folder_rounded),
  FileCategory.unknown => const _Dot(),
};

/// A [TypeIcon] as PNG bytes, [size] logical pixels drawn at [scale], for
/// what draws outside Flutter: the island (macos/Runner/Island.swift,
/// windows/runner/island.cpp, linux/runner/island.cc).
Future<Uint8List> typeIconPng(
  FileCategory category, {
  double size = 34,
  double scale = 2,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale);
  paintTypeIcon(canvas, category, size);
  final px = (size * scale).round();
  final image = await recorder.endRecording().toImage(px, px);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// [TypeIcon]'s tile and glyph on [canvas], [size] wide, the same layout.
void paintTypeIcon(Canvas canvas, FileCategory category, double size) {
  canvas.drawPath(
    bucketPath(Size.square(size)),
    Paint()..color = const Color(0xFFF5F5F5),
  );
  final s = size * 0.52;
  // Glyph sits a little above centre, clear of the curved bottom.
  final centre = Offset(size / 2, (size - size * 0.12) / 2);
  void text(String t, TextStyle style) {
    final p = TextPainter(
      text: TextSpan(text: t, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    p.paint(canvas, centre - Offset(p.width / 2, p.height / 2));
    p.dispose();
  }

  switch (_glyphOf(category)) {
    case _Icon(:final data):
      text(
        String.fromCharCode(data.codePoint),
        TextStyle(
          fontFamily: data.fontFamily,
          package: data.fontPackage,
          fontSize: s,
          height: 1,
          color: _ink,
        ),
      );
    case _Label(text: final t, :final scale):
      text(t, _labelStyle(s * scale));
    case _Zipper():
      canvas.save();
      canvas.translate(centre.dx - s / 2, centre.dy - s / 2);
      const _ZipperPainter(_ink).paint(canvas, Size.square(s));
      canvas.restore();
    case _Dot():
      canvas.drawCircle(centre, s * 0.15, Paint()..color = _ink);
  }
}

/// The plop bucket silhouette: a rounded top, sides that flare slightly, and
/// a concave bottom edge.
Path bucketPath(Size size) {
  final w = size.width, h = size.height;
  return Path()
    ..moveTo(0.22 * w, 0.04 * h)
    ..lineTo(0.78 * w, 0.04 * h)
    // top-right corner
    ..cubicTo(0.89 * w, 0.04 * h, 0.93 * w, 0.09 * h, 0.935 * w, 0.19 * h)
    // right side, flaring out slightly
    ..lineTo(0.975 * w, 0.76 * h)
    // bottom-right flare, curling back in
    ..cubicTo(0.99 * w, 0.92 * h, 0.92 * w, 0.97 * h, 0.82 * w, 0.92 * h)
    // concave bottom edge
    ..cubicTo(0.64 * w, 0.84 * h, 0.36 * w, 0.84 * h, 0.18 * w, 0.92 * h)
    ..cubicTo(0.08 * w, 0.97 * h, 0.01 * w, 0.92 * h, 0.025 * w, 0.76 * h)
    ..lineTo(0.065 * w, 0.19 * h)
    ..cubicTo(0.07 * w, 0.09 * h, 0.11 * w, 0.04 * h, 0.22 * w, 0.04 * h)
    ..close();
}

class _BucketPainter extends CustomPainter {
  const _BucketPainter();

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    bucketPath(size),
    Paint()..color = const Color(0xFFF5F5F5),
  );

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BucketClipper extends CustomClipper<Path> {
  const _BucketClipper();

  @override
  Path getClip(Size size) => bucketPath(size);

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// An image thumbnail in the bucket silhouette, so a row keeps its shape when
/// a download finishes. The mid-grey backing keeps transparent PNGs visible
/// whether their artwork is dark or light.
class BucketThumb extends StatelessWidget {
  const BucketThumb(this.image, {super.key, this.size = 32});

  final Widget image;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: ClipPath(
      clipper: const _BucketClipper(),
      child: ColoredBox(color: const Color(0xFF3A3A3A), child: image),
    ),
  );
}

/// Zipper teeth over a pull tab, for archives.
class _ZipperPainter extends CustomPainter {
  const _ZipperPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final paint = Paint()..color = color;
    final cx = s / 2;
    for (var i = 0; i < 3; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx, s * (0.16 + i * 0.17)),
            width: s * 0.16,
            height: s * 0.09,
          ),
          Radius.circular(s * 0.04),
        ),
        paint,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, s * 0.76),
          width: s * 0.17,
          height: s * 0.28,
        ),
        Radius.circular(s * 0.085),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _ZipperPainter oldDelegate) => false;
}
