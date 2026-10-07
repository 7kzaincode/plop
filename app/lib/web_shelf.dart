import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plop_core/plop_core.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'settings.dart';
import 'theme.dart';

/// Turns on the web shelf, for phones that cannot get the app (iPhones
/// without a paid Apple account), with the app's icon for their home
/// screens. [remember] keeps the node's port for the next launch, so the
/// address saved on a phone keeps working; a second instance (a dev build
/// beside the installed plop) shares the settings file and must not move
/// the installed plop's address.
Future<void> startWebShelf(
  PlopNode node,
  Settings settings, {
  required bool remember,
}) async {
  if (remember) settings.webPort = node.port;
  final icon = await rootBundle.load('assets/icon/icon.png');
  node.web
    ..enabled = true
    ..iconPng = icon.buffer.asUint8List(icon.offsetInBytes, icon.lengthInBytes);
}

/// The settings panel's "open on a phone" section: the web shelf's first
/// address as a QR code to point a camera at, and as a line that copies on
/// a tap, with what to do once it is open. The code is drawn in the text
/// colour on the panel, which phone cameras read as readily as black on
/// white; the panel itself is the quiet zone.
class PhoneLink extends StatefulWidget {
  const PhoneLink(this.node, {super.key, required this.recording});
  final PlopNode node;

  /// While a shortcut is being recorded, Enter and Space are keys being
  /// offered as the new binding, not presses of the address.
  final bool recording;

  @override
  State<PhoneLink> createState() => _PhoneLinkState();
}

class _PhoneLinkState extends State<PhoneLink> {
  List<String>? _urls; // best first; null while they are looked up
  bool _copied = false;
  bool _hover = false;
  bool _focused = false;
  Timer? _copiedTimer;

  /// The drawn code is about 140px; the rest is quiet zone.
  static const _size = 156.0;

  static final _pressKeys = [
    const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false),
    const SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false),
  ];

  @override
  void initState() {
    super.initState();
    widget.node.webUrls.then((u) {
      if (mounted) setState(() => _urls = u);
    });
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: _urls!.first));
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(height: 20, color: Palette.line),
      Text('open on a phone · on the same wi-fi', style: monoStyle(size: 11)),
      const SizedBox(height: 10),
      ..._body(),
    ],
  );

  List<Widget> _body() {
    final urls = _urls;
    // Looked up in a moment; hold the space so the panel does not jump.
    if (urls == null) return const [SizedBox(height: _size)];
    if (urls.isEmpty) {
      return [Text('not on a network right now', style: monoStyle(size: 11))];
    }
    final lit = _hover || _focused;
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: QrImageView(
          data: urls.first,
          size: _size,
          padding: const EdgeInsets.all(8),
          backgroundColor: Colors.transparent,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Palette.text,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Palette.text,
          ),
          semanticsLabel: 'qr code for ${urls.first}',
        ),
      ),
      // Tab reaches the address and Enter or Space copies it, with the
      // panel's hairline ring while focused.
      Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          button: true,
          child: Focus(
            onFocusChange: (f) => setState(() => _focused = f),
            onKeyEvent: (_, e) {
              if (widget.recording ||
                  !_pressKeys.any(
                    (k) => k.accepts(e, HardwareKeyboard.instance),
                  )) {
                return KeyEventResult.ignored;
              }
              _copy();
              return KeyEventResult.handled;
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _copy,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _focused ? Palette.border : Colors.transparent,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _copied ? 'copied' : urls.first,
                    style: monoStyle(color: lit ? Palette.text : Palette.dim),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 4, top: 2),
        child: Text(
          'then share › add to home screen',
          style: monoStyle(size: 11, color: Palette.faint),
        ),
      ),
    ];
  }
}
