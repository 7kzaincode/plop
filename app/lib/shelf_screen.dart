import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plop_core/plop_core.dart';

import 'grab.dart';
import 'hotkeys.dart';
import 'settings.dart';
import 'settings_panel.dart';
import 'theme.dart';
import 'tray.dart';
import 'type_icons.dart';
import 'window.dart';

/// How long to wait for a peer before saying none were found. Tests
/// shorten it.
@visibleForTesting
Duration peerGrace = const Duration(seconds: 6);

const _second = Duration(seconds: 1);

/// Items fade out over this final stretch of their time.
const _fadeOut = Duration(seconds: 5);

/// Padding around a desktop icon button. The countdown that swaps places
/// with the icons uses the same inset, so the row's right edge holds still.
const _iconInset = 6.0;

final _mod = Platform.isMacOS ? '⌘' : 'Ctrl+';

/// ⌘ on macOS, Ctrl elsewhere. No repeats: a held ⌘V would plop the
/// clipboard once per repeat.
SingleActivator _cmd(LogicalKeyboardKey k) => SingleActivator(
  k,
  meta: Platform.isMacOS,
  control: !Platform.isMacOS,
  includeRepeats: false,
);

/// The two ways to grab: the shelf applies them to the newest item, a
/// focused row to itself.
final _grabKeys = [
  const SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false),
  _cmd(LogicalKeyboardKey.keyC),
];

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
  late final AppLifecycleListener _lifecycle;
  final _started = DateTime.now();
  bool _dragging = false;
  bool _oneWay = false; // as last drawn
  String _blocked = ''; // ids of the unreachable peers, as last drawn

  /// Whether another device has been nearby since launch. Once one has,
  /// nobody nearby most likely means it locked or slept, which no setting
  /// here fixes.
  bool _sawPeer = false;

  String? _toast; // null when hidden
  String _toastText = ''; // kept so the pill fades out with its text
  String? _toastAction; // the tappable word after the message
  VoidCallback? _toastTap;
  Timer? _toastTimer;

  /// Where each grabbed item was saved, so a second tap shows the file
  /// instead of saving another copy.
  final _saved = <String, String>{};

  /// Items with a grab in flight. Enter and ⌘C skip the row's own guard, and
  /// two saves of a big item would race on the same .part file.
  final _inFlight = <String>{};

  /// Where keyboard focus rests: the shelf itself, so Enter and ⌘C grab the
  /// newest item. Tab and the arrows move it onto a row; Esc brings it back.
  final _focus = FocusNode();

  PlopNode get node => widget.node;

  @override
  void initState() {
    super.initState();
    _changes = node.changes.listen((_) => setState(() {}));
    // Redraw once a second only while there is a countdown to show, the
    // "looking for devices" grace period is running, or the one-way flag or
    // the unreachable peers (both purely time-based in the core, so nothing
    // announces them) have changed; an empty shelf idles.
    _tick = Timer.periodic(_second, (_) {
      final looking =
          DateTime.now().difference(_started) <= peerGrace + _second;
      final oneWay = node.oneWay.isNotEmpty;
      if (node.items.isNotEmpty ||
          looking ||
          oneWay != _oneWay ||
          _idsOf(node.unreachable) != _blocked) {
        setState(() {});
      }
    });
    // Coming back from the background: phones may lose their socket while
    // suspended, so probe it, restart if needed and re-poll. Only iOS also
    // drops its Bonjour registration; Android's NsdManager keeps it for the
    // life of the process, and a forced re-advertise there is a goodbye that
    // makes peers drop our rows and re-add them a moment later. (revive
    // re-advertises on its own when the socket did die.)
    _lifecycle = AppLifecycleListener(
      onRestart: () =>
          node.revive(rebroadcast: Platform.isIOS).catchError((_) {}),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _changes.cancel();
    _tick.cancel();
    _toastTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  /// Shows a short message. [onTap] makes it clickable and keeps it up
  /// longer, with [action] naming what the tap does; [sticky] keeps it until
  /// the next message.
  void toast(
    String? msg, {
    String? action,
    VoidCallback? onTap,
    bool sticky = false,
  }) {
    _toastTimer?.cancel();
    setState(() {
      _toast = msg;
      if (msg != null) {
        _toastText = msg;
        _toastAction = action;
      }
      _toastTap = msg == null ? null : onTap;
    });
    if (msg == null || sticky) return;
    // Reading time: 1.8 s plus 40 ms per character past the first 20, so
    // "plopped clipboard" is brief and the Screen Recording steps get ~5 s.
    final ms = min(6000, 1800 + 40 * (msg.length - 20));
    _toastTimer = Timer(
      Duration(milliseconds: max(onTap == null ? 1800 : 4000, ms)),
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

  /// One tap on an item; a repeat while it is still running is ignored.
  Future<void> _act(BuildContext ctx, ShelfItem item, GrabAction a) async {
    if (!_inFlight.add(item.key)) return;
    try {
      await run(() => _grab(ctx, item, a));
    } finally {
      _inFlight.remove(item.key);
    }
  }

  Future<String?> _grab(BuildContext ctx, ShelfItem item, GrabAction a) async {
    if (a != GrabAction.save) return grab(ctx, node, item, a);
    final known = _saved[item.key];
    if (known != null &&
        FileSystemEntity.typeSync(known) != FileSystemEntityType.notFound) {
      await reveal(known);
      return null;
    }
    final path = await saveItem(node, item);
    _saved[item.key] = path;
    final where = path.split(Platform.pathSeparator).reversed.skip(1).first;
    toast('saved to $where', action: 'show', onTap: () => reveal(path));
    return null;
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
        // Phones' pickers hand over a copy in the app cache, not the file.
        await (isDesktop ? node.addPath(p) : addCopy(node, p));
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

  /// ⌘C / Enter with no row focused: grab the newest thing someone else put
  /// on the shelf.
  void _grabNewest() {
    final it = node.items.where((i) => i.originId != node.id).firstOrNull;
    if (it != null) _act(context, it, actionsFor(it).first);
  }

  void _setTtl(Duration d) {
    setState(() => node.ttl = d);
    widget.settings.ttl = d;
  }

  /// Who has a copy of one of your own items: 'on Zain's iPhone', 'on a and
  /// b', or a count once there are more, or once a name is gone (a peer that
  /// grabbed and left). Null while nobody has it.
  String? _receivedBy(ShelfItem item) {
    final ids = item.receivedBy;
    if (ids.isEmpty) return null;
    final names = [for (final id in ids) ?node.peerName(id)];
    if (names.length == ids.length && names.length <= 2) {
      return 'on ${names.join(' and ')}';
    }
    return ids.length == 1 ? 'on 1 device' : 'on ${ids.length} devices';
  }

  static String _idsOf(List<Peer> peers) => peers.map((p) => p.id).join(',');

  /// What the shelf says about who is around, when that needs help: a
  /// device that reaches this one but that this one cannot reach (its
  /// firewall, as a rule), or, once the search is over, nobody at all.
  /// The fix for a blocked device is on that device, whose system plop
  /// cannot tell from here; plop there spells it out under its own bar
  /// ("others can't reach this device", with that system's steps).
  _Help? _help(List<Peer> peers, List<Peer> blocked, bool searching) {
    if (blocked.isNotEmpty) {
      final names = blocked.length <= 2
          ? blocked.map((p) => p.name).join(' and ')
          : '${blocked.length} devices';
      final whose = blocked.length == 1
          ? 'its firewall is'
          : 'their firewalls are';
      return (
        what: "can't reach $names · $whose blocking plop",
        fix: 'plop there says how to let it through',
        color: Palette.warn,
        quiet: false,
      );
    }
    if (peers.isNotEmpty || searching) return null;
    // A device that was here and went quiet comes back on its own; the
    // settings that keep one from ever showing up are beside the point.
    return _sawPeer
        ? (
            what: 'the other device asleep?',
            fix: 'a phone only sees the shelf while plop is in front',
            color: Palette.dim,
            quiet: true,
          )
        : (
            what: 'other device not showing up?',
            fix: _fixHint(),
            color: Palette.dim,
            quiet: false,
          );
  }

  /// Whether every device nearby holds one of your own items, and at least
  /// one does. Mirrors are never re-served, so until then a big item still
  /// needs this device around for the rest to fetch it from.
  bool _allHave(ShelfItem item) =>
      item.receivedBy.isNotEmpty &&
      node.peers.every((p) => item.receivedBy.contains(p.id));

  @override
  Widget build(BuildContext context) {
    final items = node.items;
    final peers = node.peers, blocked = node.unreachable;
    final oneWay = _oneWay = node.oneWay.isNotEmpty;
    _blocked = _idsOf(blocked);
    _sawPeer |= peers.isNotEmpty;
    final searching = DateTime.now().difference(_started) < peerGrace;
    final help = _help(peers, blocked, searching);
    // Help about who is around: the empty state says it while the shelf is
    // empty, a line under the bar once it is not, and the tooltip on the
    // bar's count of devices always. The asleep note never takes that line: it
    // comes and goes each time a phone locks, and would shove the rows
    // about.
    final lines = [
      if (oneWay)
        ("others can't reach this device · ${_inboundHint()}", Palette.warn),
      if (help != null && items.isNotEmpty && !help.quiet)
        ('${help.what} · ${help.fix}', help.color),
    ];
    final body = Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TopBar(
              peers: [for (final p in peers) p.name],
              oneWay: oneWay,
              blocked: blocked.length,
              help: help == null ? null : '${help.what}\n${help.fix}',
              self: node.store.nodeName,
              searching: searching,
              ttl: node.ttl,
              onTtl: _setTtl,
              onAddFiles: () => run(() => _add(pickFiles)),
              onAddFolder: () => run(() => _add(pickFolder)),
              onSettings: () async {
                await showSettings(
                  context,
                  widget.settings,
                  node: node,
                  onQuit: () => Tray.quit(node).ignore(),
                );
                if (mounted) setState(() {}); // shortcut labels may change
              },
            ),
            const Divider(height: 1, thickness: 1, color: Palette.line),
            for (final (line, color) in lines)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Text(line, style: monoStyle(size: 11, color: color)),
              ),
            Expanded(
              child: items.isEmpty
                  ? _empty(help)
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
                              receivedBy: _receivedBy(it),
                              allHave: _allHave(it),
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
                child: _Toast(
                  _toastText,
                  action: _toastAction,
                  onTap: _toastTap,
                ),
              ),
            ),
          ),
        ),
      ],
    );

    return CallbackShortcuts(
      bindings: {
        _cmd(LogicalKeyboardKey.keyV): () => run(paste),
        _cmd(LogicalKeyboardKey.keyO): () => run(() => _add(pickFiles)),
        const SingleActivator(LogicalKeyboardKey.escape): _focus.requestFocus,
      },
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        // Tab goes straight to the controls and rows, never back here.
        skipTraversal: true,
        // Enter and ⌘C grab the newest item only while the shelf itself has
        // focus. Not a shortcut above the tree: that would see Enter before
        // a focused TTL chip or row does and grab instead of activating it.
        onKeyEvent: (node, e) {
          if (!node.hasPrimaryFocus ||
              !_grabKeys.any((k) => k.accepts(e, HardwareKeyboard.instance))) {
            return KeyEventResult.ignored;
          }
          _grabNewest();
          return KeyEventResult.handled;
        },
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

  Widget _empty(_Help? help) {
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
            // iPhones cannot get the app; the web shelf is the way in.
            if (isDesktop) ...[
              SizedBox(height: Hotkeys.supported ? 6 : 14),
              Text(
                'phones without the app: settings › open on a phone',
                textAlign: TextAlign.center,
                style: monoStyle(size: 11, color: Palette.faint),
              ),
            ],
            if (help != null) ...[
              const SizedBox(height: 18),
              Text(
                '${help.what}\n${help.fix}',
                textAlign: TextAlign.center,
                style: monoStyle(size: 11, color: help.color),
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

/// What to check when peers can see this device but cannot connect to it.
/// Phones have no firewall of their own, and the other device's firewall
/// only guards what comes in to it; what keeps it from reaching us is a
/// Mac without Local Network permission for plop.
String _inboundHint() => Platform.isWindows
    ? 'Windows Security › Firewall › Allow an app › plop (Private and Public)'
    : Platform.isMacOS
    ? 'System Settings › Network › Firewall › allow plop'
    : Platform.isIOS || Platform.isAndroid
    ? 'check the other device · a Mac needs Local Network permission for plop'
    : 'a firewall here is blocking incoming connections';

/// Something the shelf says about who is around ([ShelfScreenState._help]):
/// what is going on, what to do about it, and in what colour. A [quiet]
/// one is never a line under the bar.
typedef _Help = ({String what, String fix, Color color, bool quiet});

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
    required this.oneWay,
    required this.blocked,
    required this.help,
    required this.self,
    required this.searching,
    required this.ttl,
    required this.onTtl,
    required this.onAddFiles,
    required this.onAddFolder,
    required this.onSettings,
  });

  final List<String> peers;

  /// Peers can be reached but cannot reach us back.
  final bool oneWay;

  /// How many peers reach us but cannot be reached.
  final int blocked;

  /// What to do about who is, or is not, around; for the tooltip.
  final String? help;
  final String self;
  final bool searching;
  final Duration ttl;
  final ValueChanged<Duration> onTtl;
  final VoidCallback onAddFiles;
  final VoidCallback onAddFolder;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final (dot, label) = peers.isNotEmpty
        ? (
            oneWay || blocked > 0 ? Palette.warn : Palette.live,
            '${peers.length} nearby',
          )
        : blocked > 0
        ? (Palette.warn, '$blocked unreachable')
        : searching
        ? (Palette.faint, 'looking…')
        : (Palette.faint, 'just you');
    // macOS: the bar shares the title bar's row, right of the traffic
    // lights, and dragging it moves the window.
    final mac = MacWindow.titlebar > 0;
    final bar = SizedBox(
      height: mac ? MacWindow.titlebar : 44,
      child: Padding(
        padding: EdgeInsets.only(left: mac ? 78 : 12, right: 12),
        child: Row(
          children: [
            // Desktop windows already carry the name in their title bar;
            // only phones need the wordmark here.
            if (!isDesktop) ...[
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
            ],
            const Spacer(),
            Tooltip(
              message: [
                'you · $self',
                ...peers,
                if (oneWay) "they can't open your plops",
                ?help,
              ].join('\n'),
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
              child: _Chip(icon: Icons.timer_rounded, label: formatTtl(ttl)),
            ),
            if (isDesktop) ...[
              const SizedBox(width: 4),
              if (Platform.isMacOS)
                _IconAction(
                  icon: Icons.add_rounded,
                  tip: 'add files or folders (⌘O)',
                  onTap: onAddFiles,
                )
              else
                PopupMenuButton<bool>(
                  tooltip: 'add (Ctrl+O)',
                  position: PopupMenuPosition.under,
                  borderRadius: BorderRadius.circular(6),
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
                  child: const _HoverIcon(Icons.add_rounded),
                ),
              _IconAction(
                icon: Icons.tune_rounded,
                tip: 'shortcuts and settings',
                onTap: onSettings,
              ),
            ],
          ],
        ),
      ),
    );
    if (!mac) return bar;
    return Stack(
      children: [
        // Behind the controls, so it never competes with them for taps.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => MacWindow.drag(),
            onDoubleTap: MacWindow.zoom,
          ),
        ),
        bar,
      ],
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    super.key,
    required this.item,
    required this.mine,
    required this.receivedBy,
    required this.allHave,
    required this.saved,
    required this.onAction,
    required this.onRemove,
  });

  final ShelfItem item;
  final bool mine;

  /// Which other devices hold an own item, once any does.
  final String? receivedBy;

  /// Whether every device nearby is among them; until then a big own item
  /// still needs this device up, as it is the only place to fetch it from.
  final bool allHave;
  final bool saved;
  final Future<void> Function(BuildContext context, GrabAction action) onAction;
  final VoidCallback onRemove;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hover = false;
  bool _focused = false; // keyboard focus, via Tab or the arrows
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
      ?widget.receivedBy,
      // A big item is fetched only when grabbed, and only ever from here, so
      // the row says the sender must stay until every device nearby has it.
      if (widget.mine && item.size > defaultEagerCopyBytes && !widget.allHave)
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

    // A focused row looks hovered, plus a hairline ring, and Enter or ⌘C
    // does what a click would. Rows with nothing to do are skipped.
    final lit = _hover || _focused;
    final row = Focus(
      canRequestFocus: actions.isNotEmpty,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, e) {
        // Keys also bubble up from a focused child icon, e.g. the × on an
        // own folder row, which has no actions of its own.
        if (actions.isEmpty ||
            !_grabKeys.any((k) => k.accepts(e, HardwareKeyboard.instance))) {
          return KeyEventResult.ignored;
        }
        _act(actions.first);
        return KeyEventResult.handled;
      },
      child: MouseRegion(
        cursor: actions.isEmpty ? MouseCursor.defer : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: actions.isEmpty ? null : () => _act(actions.first),
          child: Container(
            color: _flash
                ? Palette.pressed
                : lit
                ? Palette.hover
                : Colors.transparent,
            foregroundDecoration: _focused
                ? BoxDecoration(border: Border.all(color: Palette.border))
                : null,
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
                            _Name(item),
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
                          child: lit && icons.isNotEmpty
                              ? Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: icons,
                                )
                              : Align(
                                  alignment: Alignment.centerRight,
                                  child: Padding(
                                    padding: const EdgeInsets.only(
                                      right: _iconInset,
                                    ),
                                    child: countdown,
                                  ),
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
      ),
    );

    // New items slide in; expiring ones fade out.
    final opacity = item.progress != null
        ? 1.0
        : (left.inMilliseconds / _fadeOut.inMilliseconds).clamp(0.0, 1.0);
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

/// The item's name on one line. A long file name truncates in the middle,
/// never at the end: the tail is what tells "…at 14.23.11.png" from "…at
/// 14.23.14.png" or "v3" from "v3 (copy)". Text items have no such tail and
/// keep the end ellipsis; so do names in a right-to-left script, where a
/// head and a tail laid out left to right would swap places.
class _Name extends StatelessWidget {
  const _Name(this.item);
  final ShelfItem item;

  static const _style = TextStyle(
    fontSize: 13.5,
    color: Palette.text,
    height: 1.25,
  );

  /// Hebrew through Arabic Extended-A.
  static final _rtl = RegExp(r'[\u0590-\u08FF]');

  @override
  Widget build(BuildContext context) {
    final name = item.name;
    if (item.kind == ItemKind.text || _rtl.hasMatch(name)) return _end(name);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Measure in the style Text will draw with, so the tail's measured
        // width is the width it takes in the row.
        var style = DefaultTextStyle.of(context).style.merge(_style);
        if (MediaQuery.boldTextOf(context)) {
          style = style.merge(const TextStyle(fontWeight: FontWeight.bold));
        }
        final painter = TextPainter(
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
          maxLines: 1,
        );
        double widthOf(String s) {
          painter
            ..text = TextSpan(text: s, style: style)
            ..layout();
          return painter.width;
        }

        try {
          if (!width.isFinite || widthOf(name) <= width) {
            return Text(name, maxLines: 1, softWrap: false, style: _style);
          }
          // Counted in grapheme clusters, not UTF-16 units: a cut inside an
          // emoji or a combining mark would leave half a character on each
          // side. The tail cannot shrink, so it gives up characters until it
          // takes at most half the width; otherwise a wide script (CJK runs
          // a full em per character) pushes the row past its edge.
          final chars = name.characters;
          var keep = min(12, chars.length ~/ 2);
          while (keep > 0 &&
              widthOf(chars.takeLast(keep).toString()) > width / 2) {
            keep--;
          }
          if (keep == 0) return _end(name);
          return Row(
            children: [
              Flexible(child: _end(chars.skipLast(keep).toString())),
              Text(chars.takeLast(keep).toString(), style: _style),
            ],
          );
        } finally {
          painter.dispose();
        }
      },
    );
  }

  /// One line, giving way at the end. Sized to the line as drawn, not to
  /// the width offered, so a tail laid beside a cut head hugs its ellipsis
  /// instead of leaving the slack of the glyph that did not fit.
  static Widget _end(String s) => Text(
    s,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
    textWidthBasis: TextWidthBasis.longestLine,
    style: _style,
  );
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

/// The row divider, doubling as a countdown (or download progress) bar. The
/// fill is opaque: translucent white on [Palette.line] came out a shade
/// nobody could tell from the line itself.
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
          child: Container(color: bright ? Palette.text : Palette.faint),
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
  bool _flash = false;
  bool _focused = false;

  static final _activateKeys = [
    const SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false),
    const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false),
  ];

  void _tap() {
    setState(() => _flash = true);
    Timer(const Duration(milliseconds: 160), () {
      if (mounted) setState(() => _flash = false);
    });
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: widget.tip,
    // Tab reaches it; Enter or Space is a tap, with the hairline ring while
    // focused. The keys are handled here rather than left to ActivateIntent
    // because a row's own Focus sits above and would take Enter first.
    child: Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, e) {
        if (!_activateKeys.any(
          (k) => k.accepts(e, HardwareKeyboard.instance),
        )) {
          return KeyEventResult.ignored;
        }
        _tap();
        return KeyEventResult.handled;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _tap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _flash ? Palette.pressed : null,
            border: _focused ? Border.all(color: Palette.border) : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: _HoverIcon(
            widget.icon,
            lit: _focused,
            // Phones get a 36x40 target that still fits the row height.
            padding: isDesktop
                ? const EdgeInsets.all(_iconInset)
                : const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          ),
        ),
      ),
    ),
  );
}

/// A 16px glyph that brightens under the pointer, or while [lit]; the
/// padding is part of the hover target.
class _HoverIcon extends StatefulWidget {
  const _HoverIcon(
    this.icon, {
    this.lit = false,
    this.padding = const EdgeInsets.all(_iconInset),
  });
  final IconData icon;
  final bool lit;
  final EdgeInsets padding;

  @override
  State<_HoverIcon> createState() => _HoverIconState();
}

class _HoverIconState extends State<_HoverIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: Padding(
      padding: widget.padding,
      child: Icon(
        widget.icon,
        size: 16,
        color: _hover || widget.lit ? Palette.text : Palette.dim,
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

/// The message pill. With an [action] the message goes dim and the action
/// word takes the text colour, the app's usual passive/active split, so it
/// reads as something to click rather than the end of a sentence.
class _Toast extends StatelessWidget {
  const _Toast(this.text, {this.action, this.onTap});
  final String text;
  final String? action;
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
        child: action == null
            ? Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: monoStyle(color: Palette.text),
              )
            // Inline while it fits in two lines; otherwise the action gets
            // its own line, so the ellipsis can only ever eat the message,
            // never the one word that says what a tap does.
            : LayoutBuilder(
                builder: (context, c) {
                  final span = TextSpan(
                    text: text,
                    style: monoStyle(color: Palette.dim),
                    children: [
                      TextSpan(
                        text: '  ·  $action',
                        style: monoStyle(color: Palette.text),
                      ),
                    ],
                  );
                  final p = TextPainter(
                    text: span,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.ltr,
                    textScaler: MediaQuery.textScalerOf(context),
                  )..layout(maxWidth: c.maxWidth);
                  final over = p.didExceedMaxLines;
                  p.dispose();
                  if (!over) {
                    return Text.rich(
                      span,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                    );
                  }
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: monoStyle(color: Palette.dim),
                      ),
                      Text('·  $action', style: monoStyle(color: Palette.text)),
                    ],
                  );
                },
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
