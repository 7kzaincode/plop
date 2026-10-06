import 'dart:io';

import 'package:flutter/services.dart';

/// The macOS window draws its own title bar area (see MainFlutterWindow.swift).
abstract final class MacWindow {
  static const _channel = MethodChannel('plop/window');

  /// Height of the title bar the content runs under; 0 elsewhere.
  static double titlebar = 0;

  static Future<void> init() async {
    if (!Platform.isMacOS) return;
    try {
      titlebar = await _channel.invokeMethod<double>('titlebar') ?? 32;
    } catch (_) {
      titlebar = 32;
    }
    if (titlebar < 28) titlebar = 32;
  }

  static void drag() => _channel.invokeMethod<void>('drag').ignore();
  static void zoom() => _channel.invokeMethod<void>('zoom').ignore();
}
