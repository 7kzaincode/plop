import 'package:flutter/material.dart';

/// A near-black, mostly monochrome palette.
abstract final class Palette {
  static const bg = Color(0xFF0A0A0A);
  static const hover = Color(0xFF141414);
  static const line = Color(0xFF1F1F1F);
  static const border = Color(0xFF2A2A2A);
  static const text = Color(0xFFEDEDED);
  static const dim = Color(0xFF8B8B8B);
  static const faint = Color(0xFF555555);
  static const live = Color(0xFF3FB950);
  static const warn = Color(0xFFE5484D);
}

const sans = 'Geist';
const mono = 'GeistMono';

TextStyle monoStyle({
  double size = 12,
  Color color = Palette.dim,
  FontWeight weight = FontWeight.w400,
}) => TextStyle(
  fontFamily: mono,
  fontSize: size,
  color: color,
  fontWeight: weight,
  height: 1.3,
  fontFeatures: const [FontFeature.tabularFigures()],
);

ThemeData plopTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Palette.bg,
    canvasColor: Palette.bg,
    fontFamily: sans,
    colorScheme: const ColorScheme.dark(
      surface: Palette.bg,
      primary: Palette.text,
      onPrimary: Palette.bg,
      secondary: Palette.dim,
      error: Palette.warn,
      outline: Palette.border,
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Palette.hover,
    dividerColor: Palette.line,
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        border: Border.all(color: Palette.border),
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: monoStyle(size: 11, color: Palette.text),
      waitDuration: const Duration(milliseconds: 400),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: const Color(0xFF111111),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Palette.border),
      ),
      textStyle: monoStyle(color: Palette.text),
    ),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: Palette.text,
      displayColor: Palette.text,
    ),
  );
}
