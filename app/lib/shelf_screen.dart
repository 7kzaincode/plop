import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plop_core/plop_core.dart';

import 'grab.dart';
import 'hotkeys.dart';
import 'settings.dart';
import 'theme.dart';
import 'type_icons.dart';

/// How long to wait for a peer before saying none were found.
const _peerGrace = Duration(seconds: 6);

const _second = Duration(seconds: 1);

/// Items fade out over this final stretch of their time.
const _fadeOut = Duration(seconds: 5);

final _mod = Platform.isMacOS ? '⌘' : 'Ctrl+';

class ShelfScreen extends StatefulWidget {
  const ShelfScreen({super.key, required this.node, required this.settings});

  final PlopNode node;
  final Settings settings;

  @override
  State<ShelfScreen> createState() => ShelfScreenState();
}

class ShelfScreenState extends State<ShelfScreen> {
  late final StreamSubscription<void> _changes;
  late final Timer _tick;
  final _started = DateTime.now();
  bool _dragging = false;

  String? _toast; // null when hidden
  String _toastText = ''; // kept so the pill fades out with its text
  VoidCallback? _toastTap;
  Timer? _toastTimer;

  /// Where each grabbed item was saved, so a second tap shows the file
  /// instead of saving another copy.
  final _saved = <String, String>{};

  PlopNode get node => widget.node;

  @override
  void initState() {
    super.initState();
    _changes = node.changes.listen((_) => setState(() {}));
    // Redraw once a second only while there is a countdown to show or the
    // "looking for devices" grace period is running; an empty shelf idles.
    _tick = Timer.periodic(_second, (_) {
      final looking =
          DateTime.now().difference(_started) <= _peerGrace + _second;
      if (node.items.isNotEmpty || looking) setState(() {});
    });
  }

  @override
  void dispose() {
    _changes.cancel();
    _tick.cancel();
    _toastTimer?.cancel();
    super.dispose();
  }

  /// Shows a short message. [onTap] makes it clickable and keeps it up
  /// longer; [sticky] keeps it until the next message.
  void toast(String? msg, {VoidCallback? onTap, bool sticky = false}) {
    _toastTimer?.cancel();
    setState(() {
      _toast = msg;
      if (msg != null) _toastText = msg;
      _toastTap = msg == null ? null : onTap;
    });
    if (msg == null || sticky) return;
    _toastTimer = Timer(
      Duration(milliseconds: onTap == null ? 1800 : 4000),
      () {
        if (mounted) setState(() => _toast = _toastTap = null);
      },
    );
  }

  /// Runs a UI action, showing its message or a friendly error.
  Future<void> run(Future<String?> Function() action) async {
    try {
      final msg = await action();
      if (msg != null) toast(msg);
    } catch (e) {
      toast(friendlyError(e));
    }
  }

  /// One tap on an item.
  Future<void> _act(BuildContext ctx, ShelfItem item, GrabAction a) async {
    if (a != GrabAction.save) return run(() => grab(ctx, node, item, a));
    final known = _saved[item.key];
    if (known != null &&
        FileSystemEntity.typeSync(known) != FileSystemEntityType.notFound) {
      await reveal(known);
      return;
    }
    try {
      final path = await saveItem(node, item);
      _saved[item.key] = path;
      final where = path.split(Platform.pathSeparator).reversed.skip(1).first;
      toast('saved to $where  ·  show', onTap: () => reveal(path));
    } catch (e) {
      toast(friendlyError(e));
    }
  }

  /// Adds picked or dropped paths, carrying on past failures.
  Future<String?> _add(Future<List<String>> Function() pick) async {
    final paths = await pick();
    Object? first;
    var failed = 0;
    for (final p in paths) {
      final name = p.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;
      // Zipping a big folder takes a while before its row appears.
      if (await FileSystemEntity.isDirectory(p)) {
        toast('packing $name…', sticky: true);
      }
      try {
        await node.addPath(p);
      } catch (e) {
        failed++;
        first ??= e;
      }
    }
    if (_toast?.startsWith('packing') ?? false) toast(null);
    if (first == null) return null;
    final why = friendlyError(first);
    return failed > 1 ? '$why · ${failed - 1} more failed' : why;
  }

  Future<String?> paste() async =>
      await pasteInto(node) ? null : 'nothing to paste';

  /// ⌘C / Enter: grab the newest thing someone else put on the shelf.
  void _grabNewest() {
    final it = node.items.where((i) => i.originId != node.id).firstOrNull;
    if (it != null) _act(context, it, actionsFor(it).first);
  }

  void _setTtl(Duration d) {
    setState(() => node.ttl = d);
    widget.settings.ttl = d;
  }

  @override
  Widget build(BuildContext context) {
    final items = node.items;
    final body = Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TopBar(
              peers: [for (final p in node.peers) p.name],
              self: node.store.nodeName,
              searching: DateTime.now().difference(_started) < _peerGrace,
              ttl: node.ttl,
              onTtl: _setTtl,
              onAddFiles: () => run(() => _add(pickFiles)),
              onAddFolder: () => run(() => _add(pickFolder)),
            ),
            const Divider(height: 1, thickness: 1, color: Palette.line),
            Expanded(
              child: items.isEmpty
                  ? _empty()
                  // Not lazy: the shelf is short, and keyed rows keep their
                  // state, so entrance animations don't replay on scroll.
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final it in items)
                            _Row(
                              key: ValueKey(it.key),
                              item: it,
                              mine: it.originId == node.id,
                              saved: _saved.containsKey(it.key),
                              onAction: (ctx, a) => _act(ctx, it, a),
                              onRemove: () => node.remove(it.key),
                            ),
                        ],
                      ),
                    ),
            ),
            if (!isDesktop) _mobileBar(),
          ],
        ),
        if (_dragging) const _DropOverlay(),
        Positioned(
          left: 16,
          right: 16,
          bottom: isDesktop ? 20 : 84,
          child: IgnorePointer(
            ignoring: _toast == null || _toastTap == null,
            child: Center(
              child: AnimatedOpacity(
                opacity: _toast == null ? 0 : 1,
                duration: const Duration(milliseconds: 150),
                child: _Toast(_toastText, onTap: _toastTap),
              ),
            ),
          ),
        ),
      ],
    );

    SingleActivator cmd(LogicalKeyboardKey k) =>
        SingleActivator(k, meta: Platform.isMacOS, control: !Platform.isMacOS);
    return CallbackShortcuts(
      bindings: {
        cmd(LogicalKeyboardKey.keyV): () => run(paste),
        cmd(LogicalKeyboardKey.keyO): () => run(() => _add(pickFiles)),
        cmd(LogicalKeyboardKey.keyC): _grabNewest,
        const SingleActivator(LogicalKeyboardKey.enter): _grabNewest,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: wrapDropTarget(
              child: body,
              onHover: (h) => setState(() => _dragging = h),
              onDrop: (paths) => run(() => _add(() async => paths)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _empty() {
    final alone =
        node.peers.isEmpty && DateTime.now().difference(_started) >= _peerGrace;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(
              opacity: 0.18,
              child: Image.asset('assets/brand/logo.png', height: 64),
            ),
            const SizedBox(height: 20),
            Text(
              isDesktop
                  ? 'drop anything  ·  ${_mod}V to paste'
                  : 'add a photo, a file, or paste',
              textAlign: TextAlign.center,
              style: monoStyle(color: Palette.dim),
            ),
            const SizedBox(height: 6),
            Text(
              'anyone on this wi-fi with plop open can grab it '
              'for ${formatTtl(node.ttl)}',
              textAlign: TextAlign.center,
              style: monoStyle(size: 11, color: Palette.faint),
            ),
            if (Hotkeys.supported) ...[
              const SizedBox(height: 14),
              Text(
                '${Hotkeys.snipLabel} snip  ·  ${Hotkeys.clipLabel} clipboard'
                '  ·  from any app',
                textAlign: TextAlign.center,
                style: monoStyle(size: 11, color: Palette.faint),
              ),
            ],
            if (alone) ...[
              const SizedBox(height: 18),
              Text(
                'other device not showing up?\n${_fixHint()}',
                textAlign: TextAlign.center,
                style: monoStyle(size: 11, color: Palette.dim),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _mobileBar() => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: Palette.line)),
    ),
    child: Row(
      children: [
        for (final (icon, label, onTap) in [
          (
            Icons.photo_outlined,
            'photo',
            () => run(() => _add(() => pickFiles(media: true))),
          ),
          (
            Icons.insert_drive_file_outlined,
            'file',
            () => run(() => _add(pickFiles)),
          ),
          (Icons.content_paste_outlined, 'paste', () => run(paste)),
        ])
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _GhostButton(icon: icon, label: label, onTap: onTap),
            ),
          ),
      ],
    ),
  );
}

/// What to check when no other device shows up.
String _fixHint() => Platform.isIOS
    ? 'allow Settings › plop › Local Network'
    : Platform.isMacOS
    ? 'allow plop in System Settings › Privacy & Security › Local Network'
    : Platform.isWindows
    ? 'allow plop in Windows Firewall, or set this wi-fi to Private'
    : 'guest and campus wi-fi often block devices from seeing each other';

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.peers,
    required this.self,
    required this.searching,
    required this.ttl,
    required this.onTtl,
    required this.onAddFiles,
    required this.onAddFolder,
  });

  final List<String> peers;
  final String self;
  final bool searching;
  final Duration ttl;
  final ValueChanged<Duration> onTtl;
  final VoidCallback onAddFiles;
  final VoidCallback onAddFolder;

  @override
  Widget build(BuildContext context) {
    final (dot, label) = peers.isNotEmpty
        ? (Palette.live, '${peers.length} nearby')
        : searching
        ? (Palette.faint, 'looking…')
        : (Palette.faint, 'just you');
    final menuShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(6),
    );
    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const SizedBox(width: 4),
            Image.asset('assets/brand/logo.png', height: 16),
            const SizedBox(width: 8),
            Text(
              'plop',
              style: monoStyle(
                size: 13,
                color: Palette.text,
                weight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            Tooltip(
              message: ['you · $self', ...peers].join('\n'),
              triggerMode: isDesktop ? null : TooltipTriggerMode.tap,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: dot,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(label, style: monoStyle()),
                ],
              ),
            ),
            const SizedBox(width: 12),
            PopupMenuButton<Duration>(
              tooltip: 'how long things stay',
              initialValue: ttl,
              onSelected: onTtl,
              position: PopupMenuPosition.under,
              borderRadius: BorderRadius.circular(6),
              itemBuilder: (_) => [
                for (final d in ttlChoices)
                  PopupMenuItem(
                    value: d,
                    height: 32,
                    child: Text(
                      formatTtl(d),
                      style: monoStyle(
                        color: d == ttl ? Palette.text : Palette.dim,
                      ),
                    ),
                  ),
              ],
              child: _Chip(icon: Icons.timer_outlined, label: formatTtl(ttl)),
            ),
            if (isDesktop) ...[
              const SizedBox(width: 4),
              if (Platform.isMacOS)
                _IconAction(
                  icon: Icons.add,
                  tip: 'add files or folders (⌘O)',
                  onTap: onAddFiles,
                )
              else
                PopupMenuButton<bool>(
                  tooltip: 'add (Ctrl+O)',
                  position: PopupMenuPosition.under,
                  borderRadius: BorderRadius.circular(6),
                  shape: menuShape,
                  onSelected: (folder) => folder ? onAddFolder() : onAddFiles(),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: false,
                      height: 32,
                      child: Text(
                        'files…',
                        style: monoStyle(color: Palette.text),
                      ),
                    ),
                    PopupMenuItem(
                      value: true,
                      height: 32,
                      child: Text(
                        'folder…',
                        style: monoStyle(color: Palette.text),
                      ),
                    ),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.add, size: 16, color: Palette.dim),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    super.key,
    required this.item,
    required this.mine,
    required this.saved,
    required this.onAction,
    required this.onRemove,
  });

  final ShelfItem item;
  final bool mine;
  final bool saved;
  final Future<void> Function(BuildContext context, GrabAction action) onAction;
  final VoidCallback onRemove;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hover = false;
  bool _flash = false;
  bool _busy = false;

  /// Runs an action once: the second click of a double-click, or taps while
  /// a transfer is running, are ignored (two saves of a big item would race
  /// on the same .part file).
  Future<void> _act(GrabAction a) async {
    if (_busy) return;
    _busy = true;
    setState(() => _flash = true);
    Timer(const Duration(milliseconds: 160), () {
      if (mounted) setState(() => _flash = false);
    });
    try {
      await widget.onAction(context, a);
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final left = item.remaining;
    final ending = left < const Duration(seconds: 10);
    final fraction = item.ttl.inMilliseconds == 0
        ? 0.0
        : (left.inMilliseconds / item.ttl.inMilliseconds).clamp(0.0, 1.0);
    // Your own text and images copy on tap, handy right after a snip.
    final actions = widget.mine
        ? [
            for (final a in actionsFor(item))
              if (a == GrabAction.copy) a,
          ]
        : actionsFor(item);

    final meta = [
      if (item.kind != ItemKind.text) formatSize(item.size),
      widget.mine ? 'you' : item.originName,
      if (item.progress != null) '${(item.progress! * 100).round()}%',
      if (widget.saved) 'saved',
      if (widget.mine && item.size > defaultEagerCopyBytes)
        'keep plop open until grabbed',
    ].join('  ·  ');

    final icons = [
      for (final a in actions)
        _IconAction(
          icon: switch (a) {
            GrabAction.copy => Icons.copy_rounded,
            GrabAction.save => Icons.arrow_downward_rounded,
            GrabAction.share => Icons.ios_share_rounded,
          },
          tip: a.name,
          onTap: () => _act(a),
        ),
      if (widget.mine)
        _IconAction(
          icon: Icons.close_rounded,
          tip: 'remove',
          onTap: widget.onRemove,
        ),
    ];
    final countdown = Text(
      _countdown(left),
      textAlign: TextAlign.right,
      style: monoStyle(color: ending ? Palette.warn : Palette.dim),
    );

    final row = MouseRegion(
      cursor: actions.isEmpty ? MouseCursor.defer : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: actions.isEmpty ? null : () => _act(actions.first),
        child: Container(
          color: _flash
              ? Palette.pressed
              : _hover
              ? Palette.hover
              : Colors.transparent,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                child: Row(
                  children: [
                    _Leading(item),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13.5,
                              color: Palette.text,
                              height: 1.25,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: monoStyle(size: 11),
                          ),
                        ],
                      ),
                    ),
                    // Desktop: one fixed slot that swaps the countdown for the
                    // actions on hover, so the name never reflows.
                    if (isDesktop)
                      SizedBox(
                        width: 60,
                        child: _hover && icons.isNotEmpty
                            ? Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: icons,
                              )
                            : Align(
                                alignment: Alignment.centerRight,
                                child: countdown,
                              ),
                      )
                    else ...[
                      ...icons,
                      const SizedBox(width: 6),
                      SizedBox(width: 44, child: countdown),
                    ],
                  ],
                ),
              ),
              _Hairline(
                fraction: item.progress ?? fraction,
                bright: item.progress != null,
              ),
            ],
          ),
        ),
      ),
    );

    // New items slide in; expiring ones fade out.
    final opacity = (left.inMilliseconds / _fadeOut.inMilliseconds).clamp(
      0.0,
      1.0,
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      builder: (_, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 8),
          child: child,
        ),
      ),
      child: AnimatedOpacity(
        opacity: opacity,
        duration: const Duration(seconds: 1),
        child: row,
      ),
    );
  }

  static String _countdown(Duration d) {
    final s = (d.inMilliseconds / 1000).ceil();
    if (s >= 3600) {
      return '${s ~/ 3600}h${(s % 3600 ~/ 60).toString().padLeft(2, '0')}';
    }
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

/// Type icon, or a bucket-shaped thumbnail once an image is on this device.
class _Leading extends StatelessWidget {
  const _Leading(this.item);
  final ShelfItem item;

  @override
  Widget build(BuildContext context) {
    const size = 30.0;
    final icon = TypeIcon(categoryOf(item), size: size);
    if (!item.isReady || !isCopyableImage(item)) return icon;
    return BucketThumb(
      Image.file(
        File(item.path!),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: 90,
        errorBuilder: (_, _, _) => icon,
      ),
      size: size,
    );
  }
}

/// The row divider, doubling as a countdown (or download progress) bar.
class _Hairline extends StatelessWidget {
  const _Hairline({required this.fraction, required this.bright});
  final double fraction;
  final bool bright;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 1,
    child: Stack(
      children: [
        Container(color: Palette.line),
        FractionallySizedBox(
          widthFactor: fraction,
          child: Container(
            color: bright ? Palette.text : const Color(0x12FFFFFF),
          ),
        ),
      ],
    ),
  );
}

class _IconAction extends StatefulWidget {
  const _IconAction({
    required this.icon,
    required this.tip,
    required this.onTap,
  });
  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  State<_IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<_IconAction> {
  bool _hover = false;
  bool _flash = false;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: widget.tip,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _flash = true);
          Timer(const Duration(milliseconds: 160), () {
            if (mounted) setState(() => _flash = false);
          });
          widget.onTap();
        },
        child: Container(
          // Phones get a 36x40 target that still fits the row height.
          padding: isDesktop
              ? const EdgeInsets.all(6)
              : const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          decoration: BoxDecoration(
            color: _flash ? Palette.pressed : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            widget.icon,
            size: 16,
            color: _hover ? Palette.text : Palette.dim,
          ),
        ),
      ),
    ),
  );
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      border: Border.all(color: Palette.border),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: Palette.dim),
        const SizedBox(width: 5),
        Text(label, style: monoStyle(color: Palette.text)),
      ],
    ),
  );
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: const BorderSide(color: Palette.border),
    ),
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      highlightColor: Palette.pressed,
      onTap: onTap,
      child: SizedBox(
        height: 46,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: Palette.text),
            const SizedBox(width: 8),
            Text(label, style: monoStyle(color: Palette.text)),
          ],
        ),
      ),
    ),
  );
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      child: Container(
        color: Palette.bg.withValues(alpha: 0.88),
        padding: const EdgeInsets.all(10),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: Palette.text.withValues(alpha: 0.5)),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Text(
            'drop to plop',
            style: monoStyle(size: 13, color: Palette.text),
          ),
        ),
      ),
    ),
  );
}

class _Toast extends StatelessWidget {
  const _Toast(this.text, {this.onTap});
  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF161616),
          border: Border.all(color: const Color(0xFF2A2A2A)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: monoStyle(color: Palette.text),
        ),
      ),
    ),
  );
}

String formatSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(u == 0 || v >= 10 ? 0 : 1)} ${units[u]}';
}
