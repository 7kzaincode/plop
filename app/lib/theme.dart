import 'dart:io';

import 'package:flutter/material.dart';

/// A near-black, mostly monochrome palette. Overlays are translucent white so
/// they read the same on an opaque canvas and on the macOS glass. The three
/// text tiers all pass WCAG AA on [bg].
abstract final class Palette {
  static const bg = Color(0xFF0A0A0A);
  static const hover = Color(0x0AFFFFFF);
  static const pressed = Color(0x17FFFFFF);
  static const line = Color(0x14FFFFFF);
  static const border = Color(0x24FFFFFF);
  static const text = Color(0xFFEDEDED); // 16.9:1
  static const dim = Color(0xFFA1A1A1); // 7.7:1
  static const faint = Color(0xFF7A7A7A); // 4.6:1
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
    // On macOS the window is frosted glass; 78% black keeps text legible
    // over any wallpaper.
    scaffoldBackgroundColor: Platform.isMacOS
        ? const Color(0xC70A0A0A)
        : Palette.bg,
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
    // Keyboard focus on the few Material controls (the TTL and add menus),
    // in the palette rather than Material's 12% white.
    focusColor: Palette.pressed,
    dividerColor: Palette.line,
    scrollbarTheme: const ScrollbarThemeData(
      thickness: WidgetStatePropertyAll(4),
      radius: Radius.circular(2),
      thumbColor: WidgetStatePropertyAll(Color(0x33FFFFFF)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        border: Border.all(color: const Color(0xFF2A2A2A)),
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
        side: const BorderSide(color: Color(0xFF2A2A2A)),
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
