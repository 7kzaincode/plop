import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plop_core/plop_core.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'alias.dart';
import 'settings.dart';
import 'theme.dart';

/// Turns on the web shelf, for phones that cannot get the app (iPhones
/// without a paid Apple account), with the app's icon for their home
/// screens. [remember] keeps the node's port for later launches when none
/// is kept yet, so the address saved on a phone keeps working. Only then:
/// a launch that found the kept port taken got another for this run only,
/// and the next launch goes back to the kept one rather than strand every
/// phone that saved it. A second instance (a dev build beside the
/// installed plop) shares the settings file and must not move the
/// installed plop's address.
Future<void> startWebShelf(
  PlopNode node,
  Settings settings, {
  required bool remember,
}) async {
  if (remember && settings.webPort == null) settings.webPort = node.port;
  final icon = await rootBundle.load('assets/icon/icon.png');
  node.web
    ..enabled = true
    ..iconPng = icon.buffer.asUint8List(icon.offsetInBytes, icon.lengthInBytes);
}

/// [url] as a QR code the way the standard has it and every scanner reads
/// it: dark modules on white with a quiet zone of at least four modules,
/// on a small rounded white card. A light-on-dark code, or one with a thin
/// margin, is optional for scanners to read, and many in-app ones do not;
/// this code is how phones find the web shelf, so it stays plain.
class ShelfQr extends StatelessWidget {
  const ShelfQr(this.url, {super.key});
  final String url;

  /// Edge of the card, quiet zone included.
  static const size = 176.0;

  @override
  Widget build(BuildContext context) {
    final check = QrValidator.validate(
      data: url,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.L,
    );
    final qr = check.qrCode;
    if (!check.isValid || qr == null) return const SizedBox.shrink();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: QrImageView.withQr(
        qr: qr,
        size: size,
        padding: EdgeInsets.all(qrQuietZone(qr.moduleCount, size)),
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Colors.black,
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Colors.black,
        ),
        semanticsLabel: 'qr code for $url',
      ),
    );
  }
}

/// The margin around a code [modules] modules wide drawn on a [size]-wide
/// card: each module is the largest half-pixel step that leaves room for
/// four of them on every side, and the margin is what remains. Half-pixel
/// steps, because that is what qr_flutter rounds a module to; any other
/// edge would be rounded up into the margin.
double qrQuietZone(int modules, double size) {
  final module = (size / (modules + 8) * 2).floorToDouble() / 2;
  return (size - module * modules) / 2;
}

/// The settings panel's "open on a phone" section: the web shelf's first
/// address as a QR code to point a camera at, and as a line that copies on
/// a tap, with what to do once it is open. That is plop.local while this
/// computer or another of the user's answers for it, so the icon a phone
/// saves opens whichever is on; this computer's own address is the "or"
/// line, for a browser that cannot resolve .local names (Android's).
/// Looked up again when this computer takes the name or lets it go.
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
  StreamSubscription<AliasState>? _alias;

  static final _pressKeys = [
    const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false),
    const SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false),
  ];

  @override
  void initState() {
    super.initState();
    _lookUp();
    _alias = Alias.instance.changes.listen((_) => _lookUp());
  }

  void _lookUp() => widget.node.webUrls.then((u) {
    if (mounted) setState(() => _urls = u);
  });

  @override
  void dispose() {
    _alias?.cancel();
    _copiedTimer?.cancel();
    super.dispose();
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: shown(_urls!)));
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
    if (urls == null) return const [SizedBox(height: ShelfQr.size)];
    if (urls.isEmpty) {
      return [Text('not on a network right now', style: monoStyle(size: 11))];
    }
    final lit = _hover || _focused;
    // The QR code and the line under it give this computer's numbered
    // address, which every phone on the Wi-Fi reaches; a .local name some
    // can't resolve (Android, some networks), and a scan that hangs is the
    // end of it. The page moves itself to plop.local where the phone does
    // reach it (lib/src/web_host.dart), before it goes on a home screen.
    final main = shown(urls);
    final next = urls.firstWhere((u) => u != main, orElse: () => '');
    return [
      Align(alignment: Alignment.centerLeft, child: ShelfQr(main)),
      const SizedBox(height: 8),
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
                    _copied ? 'copied' : main,
                    style: monoStyle(color: lit ? Palette.text : Palette.dim),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      // The best named address: plop.local, or this computer's .local name.
      if (next.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            'or $next',
            style: monoStyle(size: 11, color: Palette.faint),
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

/// The address the QR code gives: the first numbered one, else the first.
@visibleForTesting
String shown(List<String> urls) => urls.firstWhere(
  (u) => InternetAddress.tryParse(Uri.parse(u).host)?.type ==
      InternetAddressType.IPv4,
  orElse: () => urls.first,
);
