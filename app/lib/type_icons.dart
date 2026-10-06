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
    final glyph = size * 0.46;
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

  Widget _glyph(double s) {
    const ink = Color(0xFF0A0A0A);
    Widget icon(IconData d) => Icon(d, size: s, color: ink);
    Widget label(String t, double k) => Text(
      t,
      style: TextStyle(
        fontFamily: 'Geist',
        fontWeight: FontWeight.w500,
        fontSize: s * k,
        height: 1,
        color: ink,
        letterSpacing: -0.2,
      ),
    );
    return switch (category) {
      FileCategory.image => icon(Icons.landscape_rounded),
      FileCategory.video => icon(Icons.play_arrow_rounded),
      FileCategory.audio => icon(Icons.music_note_rounded),
      FileCategory.document => icon(Icons.short_text_rounded),
      FileCategory.pdf => label('PDF', 0.5),
      FileCategory.code => icon(Icons.code_rounded),
      FileCategory.spreadsheet => icon(Icons.grid_view_rounded),
      FileCategory.presentation => icon(Icons.pie_chart_rounded),
      FileCategory.archive => CustomPaint(
        size: Size.square(s),
        painter: const _ZipperPainter(ink),
      ),
      FileCategory.model3d => icon(Icons.view_in_ar_rounded),
      FileCategory.project => icon(Icons.layers_rounded),
      FileCategory.data => icon(Icons.storage_rounded),
      FileCategory.executable => icon(Icons.settings_rounded),
      FileCategory.terminal => icon(Icons.terminal_rounded),
      FileCategory.font => label('Aa', 0.72),
      FileCategory.note => icon(Icons.sticky_note_2_outlined),
      FileCategory.web => icon(Icons.language_rounded),
      FileCategory.folder => icon(Icons.folder_rounded),
      FileCategory.unknown => Container(
        width: s * 0.3,
        height: s * 0.3,
        decoration: const BoxDecoration(color: ink, shape: BoxShape.circle),
      ),
    };
  }
}

class _BucketPainter extends CustomPainter {
  const _BucketPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final p = Path()
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
    canvas.drawPath(p, Paint()..color = const Color(0xFFF5F5F5));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
