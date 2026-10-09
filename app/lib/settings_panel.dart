import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:plop_core/plop_core.dart';

import 'hotkeys.dart';
import 'login_item.dart';
import 'notify.dart';
import 'settings.dart';
import 'theme.dart';
import 'tray.dart';
import 'web_shelf.dart';

/// The one settings surface: global shortcuts, open-at-login, the web
/// shelf's address when [node] serves one, private mode ([private], which
/// defaults to [node]'s), and what plop does in the background, with
/// [onQuit] behind its "quit plop" link while the tray icon is up on
/// Windows and Linux ([Tray.quitsInWindow]).
Future<void> showSettings(
  BuildContext context,
  Settings settings, {
  PlopNode? node,
  PrivateMode? private,
  VoidCallback? onQuit,
}) => showDialog<void>(
  context: context,
  barrierColor: const Color(0x99000000),
  builder: (_) => _SettingsPanel(
    settings,
    node: node,
    private: private ?? node?.private,
    onQuit: onQuit,
  ),
);

class _SettingsPanel extends StatefulWidget {
  const _SettingsPanel(this.settings, {this.node, this.private, this.onQuit});
  final Settings settings;
  final PlopNode? node;
  final PrivateMode? private;
  final VoidCallback? onQuit;

  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel> {
  String? _recording; // 'snip', 'clip' or 'grab'
  String? _note;
  bool? _login;

  /// The key chips, so recording can put focus on the one recording.
  final _keyFocus = {
    for (final which in Hotkeys.bindings.keys)
      which: FocusNode(debugLabel: '$which key'),
  };

  @override
  void initState() {
    super.initState();
    if (LoginItem.supported) {
      LoginItem.enabled.then((v) {
        if (mounted) setState(() => _login = v);
      });
    }
  }

  @override
  void dispose() {
    _stopRecording(apply: true);
    for (final f in _keyFocus.values) {
      f.dispose();
    }
    super.dispose();
  }

  void _record(String which) {
    _stopRecording(apply: false);
    Hotkeys.pause();
    HardwareKeyboard.instance.addHandler(_onKey);
    // A click may come while Tab has the reset link or the toggle focused;
    // the key being recorded takes focus, so a bare Enter or Space is
    // offered to the recorder rather than pressing whatever Tab reached.
    _keyFocus[which]!.requestFocus();
    setState(() {
      _recording = which;
      _note = 'press the new keys · esc to cancel';
    });
  }

  void _stopRecording({required bool apply}) {
    HardwareKeyboard.instance.removeHandler(_onKey);
    if (_recording == null) return;
    _recording = null;
    if (apply) Hotkeys.apply();
  }

  static final _modifierKeys = {
    for (final m in HotKeyModifier.values) ...m.physicalKeys,
  };

  bool _onKey(KeyEvent e) {
    if (e is! KeyDownEvent || _recording == null) return _recording != null;
    final key = e.physicalKey;
    if (key == PhysicalKeyboardKey.escape) {
      _stopRecording(apply: true);
      setState(() => _note = null);
      return true;
    }
    if (_modifierKeys.contains(key)) return true; // wait for the real key
    final pressed = HardwareKeyboard.instance.physicalKeysPressed;
    final mods = [
      for (final m in HotKeyModifier.values)
        if (m != HotKeyModifier.capsLock && m != HotKeyModifier.fn)
          if (m.physicalKeys.any(pressed.contains)) m,
    ];
    final k = HotKey(key: key, modifiers: mods);
    final why = Hotkeys.reject(k);
    if (why != null) {
      setState(() => _note = why);
      return true;
    }
    final which = _recording!;
    final others = {...Hotkeys.bindings}..remove(which);
    if (others.values.any((o) => Hotkeys.same(k, o))) {
      setState(() => _note = 'that one is already taken');
      return true;
    }
    if (!Hotkeys.isFree(k)) {
      setState(() => _note = 'another app already uses ${Hotkeys.label(k)}');
      return true;
    }
    switch (which) {
      case 'snip':
        Hotkeys.snip = k;
      case 'clip':
        Hotkeys.clip = k;
      default:
        Hotkeys.grab = k;
    }
    // Leave recording mode and re-register first, so a failure while saving
    // can never strand the panel on "…" with the shortcuts paused.
    _stopRecording(apply: true);
    setState(() => _note = null);
    // Future.sync also catches a synchronous throw while encoding the key.
    Future.sync(() => widget.settings.setHotkey(which, k)).catchError((_) {
      if (mounted) {
        setState(() {
          _note = "couldn't save that · it works until plop quits";
        });
      }
    });
    return true;
  }

  void _reset() {
    _stopRecording(apply: false);
    Hotkeys.snip = Hotkeys.defaultSnip;
    Hotkeys.clip = Hotkeys.defaultClip;
    Hotkeys.grab = Hotkeys.defaultGrab;
    Hotkeys.apply();
    setState(() => _note = null);
    // A file that can't be written would bring the old bindings back at
    // the next launch, unannounced; say so now instead.
    Future.wait([
      for (final which in Hotkeys.bindings.keys)
        widget.settings.setHotkey(which, null),
    ]).then<void>(
      (_) {},
      onError: (Object _) {
        if (mounted) {
          setState(() {
            _note = "couldn't save that · the defaults hold until plop quits";
          });
        }
      },
    );
  }

  Future<void> _toggleLogin(bool on) async {
    final now = await LoginItem.set(on);
    if (!mounted) return;
    setState(() {
      _login = now == LoginState.on;
      if (now == LoginState.needsApproval) {
        _note = 'approve plop in System Settings › General › Login Items';
      } else if (_login != on) {
        _note = "couldn't change that here";
      }
    });
  }

  // While a shortcut is recording, Ctrl+Q is a key being offered (and
  // refused: an everyday shortcut), not the window's quit (QuitKey, above
  // the panel), so it goes no further up.
  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (_, e) {
      final offered = _recording != null;
      return offered && Tray.quitKey.accepts(e, HardwareKeyboard.instance)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    },
    child: _panel(),
  );

  Widget _panel() {
    final label = monoStyle(color: Palette.text);
    final mod = Platform.isMacOS ? '⌘' : 'Ctrl+';
    final onQuit = widget.onQuit;
    return Dialog(
      backgroundColor: const Color(0xFF111111),
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF2A2A2A)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        // At the smallest window (360x320) a two-line note puts the panel a
        // few lines over the height it has; it scrolls rather than clips.
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (Hotkeys.supported) ...[
                Text(
                  'shortcuts · work from any app',
                  style: monoStyle(size: 11),
                ),
                const SizedBox(height: 10),
                _row(
                  'snip a screen region',
                  _Key(
                    text: _recording == 'snip' ? '…' : Hotkeys.snipLabel,
                    active: _recording == 'snip',
                    recording: _recording != null,
                    focusNode: _keyFocus['snip']!,
                    onTap: () => _record('snip'),
                  ),
                  label,
                ),
                _row(
                  'plop the clipboard',
                  _Key(
                    text: _recording == 'clip' ? '…' : Hotkeys.clipLabel,
                    active: _recording == 'clip',
                    recording: _recording != null,
                    focusNode: _keyFocus['clip']!,
                    onTap: () => _record('clip'),
                  ),
                  label,
                ),
                _row(
                  'grab newest',
                  _Key(
                    text: _recording == 'grab' ? '…' : Hotkeys.grabLabel,
                    active: _recording == 'grab',
                    recording: _recording != null,
                    focusNode: _keyFocus['grab']!,
                    onTap: () => _record('grab'),
                  ),
                  label,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _Link(
                    'reset to defaults',
                    recording: _recording != null,
                    onTap: _reset,
                  ),
                ),
              ],
              // The README promises shortcuts on Linux; say why they are
              // missing rather than leave the panel wordless.
              if (Platform.isLinux && !Hotkeys.supported)
                Text(
                  'shortcuts need an X11 (Xorg) session · '
                  'not available on Wayland',
                  style: monoStyle(size: 11),
                ),
              // The window's own keys, which nothing else in the app spells
              // out; they work on Wayland too.
              const SizedBox(height: 6),
              Text(
                'in the window: ${mod}V paste · ${mod}O add · '
                '${mod}C or ↩ grab the newest',
                style: monoStyle(size: 11, color: Palette.faint),
              ),
              const Divider(height: 20, color: Palette.line),
              if (LoginItem.supported)
                _row(
                  _loginLabel,
                  _Toggle(
                    label: _loginLabel,
                    value: _login ?? false,
                    recording: _recording != null,
                    onChanged: _login == null ? null : _toggleLogin,
                  ),
                  label,
                ),
              if (widget.node case final node?
                  when node.web.enabled && !node.private.on)
                PhoneLink(node, recording: _recording != null),
              if (widget.private case final private?)
                _PrivateSection(
                  private,
                  webShelf: widget.node?.web.enabled ?? false,
                  recording: _recording != null,
                ),
              if (Notify.supported)
                _BackgroundSection(
                  widget.settings,
                  recording: _recording != null,
                  onQuit: onQuit != null && Tray.quitsInWindow && Tray.active
                      ? onQuit
                      : null,
                ),
              if (_note != null) ...[
                const SizedBox(height: 8),
                Text(_note!, style: monoStyle(size: 11, color: Palette.dim)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String text, Widget trailing, TextStyle style) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(child: Text(text, style: style)),
        trailing,
      ],
    ),
  );
}

/// Space or Enter, once, as a press of a hand-drawn control.
final _pressKeys = [
  const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false),
  const SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false),
];

bool _isPress(KeyEvent e) =>
    _pressKeys.any((k) => k.accepts(e, HardwareKeyboard.instance));

/// The hairline focus ring the panel's controls share, standing [inset]
/// outside [child] so the control keeps its place.
Widget _ring(
  Widget child, {
  required bool focused,
  double inset = 3,
  double radius = 9,
}) => Stack(
  clipBehavior: Clip.none,
  children: [
    child,
    if (focused)
      Positioned.fill(
        left: -inset,
        top: -inset,
        right: -inset,
        bottom: -inset,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: Palette.border),
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      ),
  ],
);

/// A key-combo button that records a new binding when clicked, or on
/// Enter or Space once Tab has reached it.
class _Key extends StatefulWidget {
  const _Key({
    required this.text,
    required this.active,
    required this.recording,
    required this.focusNode,
    required this.onTap,
  });
  final String text;
  final bool active;

  /// While any shortcut is being recorded, Enter and Space are keys being
  /// offered as the new binding, not presses of this button.
  final bool recording;

  /// The panel's, so it can focus this chip when recording starts.
  final FocusNode focusNode;
  final VoidCallback onTap;

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: Focus(
      focusNode: widget.focusNode,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, e) {
        if (widget.recording || !_isPress(e)) return KeyEventResult.ignored;
        widget.onTap();
        return KeyEventResult.handled;
      },
      child: _Hover(
        builder: (_, hover) => GestureDetector(
          onTap: widget.onTap,
          child: _ring(
            focused: _focused,
            Container(
              constraints: const BoxConstraints(minWidth: 64),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: widget.active ? const Color(0x1FFFFFFF) : null,
                border: Border.all(
                  color: widget.active
                      ? Palette.text
                      : hover || _focused
                      ? Palette.dim
                      : Palette.border,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                widget.text,
                textAlign: TextAlign.center,
                style: monoStyle(color: Palette.text),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A dim line of text that acts when clicked, brightening under the pointer
/// or keyboard focus, which Tab gives it and Enter or Space press.
class _Link extends StatefulWidget {
  const _Link(this.text, {required this.recording, required this.onTap});
  final String text;

  /// See [_Key.recording]: no press while a shortcut is being recorded.
  final bool recording;
  final VoidCallback onTap;

  @override
  State<_Link> createState() => _LinkState();
}

class _LinkState extends State<_Link> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, e) {
        if (widget.recording || !_isPress(e)) return KeyEventResult.ignored;
        widget.onTap();
        return KeyEventResult.handled;
      },
      child: _Hover(
        builder: (_, hover) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: _ring(
              focused: _focused,
              inset: 2,
              radius: 4,
              Text(
                widget.text,
                style: monoStyle(
                  size: 11,
                  color: hover || _focused ? Palette.text : Palette.dim,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Private mode: a switch (it needs another paired device first), pairing
/// a device, the circle's devices with "forget", and "leave circle". Opening
/// "pair a device" lists this device nearby for two minutes, or until the
/// panel closes; lib/src/private_mode.dart in the core has the rest.
class _PrivateSection extends StatefulWidget {
  const _PrivateSection(
    this.mode, {
    required this.webShelf,
    required this.recording,
  });
  final PrivateMode mode;

  /// This device serves the web shelf when private mode is off.
  final bool webShelf;

  /// See [_Key.recording].
  final bool recording;

  @override
  State<_PrivateSection> createState() => _PrivateSectionState();
}

class _PrivateSectionState extends State<_PrivateSection> {
  static const _label = 'private mode';
  late final StreamSubscription<void> _sub;
  Timer? _tick;
  String? _note;
  bool _busy = false; // a forget or a leave running

  PrivateMode get mode => widget.mode;

  @override
  void initState() {
    super.initState();
    _sub = mode.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub.cancel();
    _tick?.cancel();
    // Pairing is the panel's: the device stops being listed once it goes.
    if (mode.pairingOpen) mode.closePairing();
    super.dispose();
  }

  void _openPairing() {
    mode.openPairing();
    _note = null;
    // The countdown.
    _tick ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (!mode.pairingOpen) {
        _tick?.cancel();
        _tick = null;
      }
    });
    setState(() {});
  }

  void _toggle(bool on) {
    mode.setOn(on).catchError((Object _) {
      if (mounted) {
        setState(
          () => _note = "couldn't save that · it holds until plop quits",
        );
      }
    });
    setState(() => _note = null);
  }

  Future<void> _forget(CircleMember m) async {
    setState(() => _busy = true);
    final missed = await mode.forget(m.publicKey);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = missed.isEmpty
          ? 'forgot ${m.name} · the others have the new key'
          : 'forgot ${m.name} · '
                "${[for (final x in missed) x.name].join(', ')} "
                "wasn't around for the new key · pair it again";
    });
  }

  Future<void> _leave() async {
    setState(() => _busy = true);
    await mode.leave();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = 'left the circle · private mode is off';
    });
  }

  String get _left {
    final until = mode.pairingUntil;
    if (until == null) return '';
    // Rounded up: it reads 2:00 as it opens, and 0:00 only at the end.
    final ms = until.difference(DateTime.now()).inMilliseconds;
    final s = ((ms + 999) ~/ 1000).clamp(0, 999);
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Widget _link(String text, VoidCallback onTap) => Align(
    alignment: Alignment.centerLeft,
    child: _Link(text, recording: widget.recording, onTap: onTap),
  );

  Widget _small(String text, {Color color = Palette.dim}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Text(text, style: monoStyle(size: 11, color: color)),
  );

  /// The pairing part: nearby devices to pick, then the number to compare.
  List<Widget> _pairing() {
    final p = mode.pairing;
    final who = p.peerName == null || p.peerName!.isEmpty
        ? 'the other device'
        : p.peerName!;
    switch (p.step) {
      case PairStep.compare || PairStep.waiting:
        final code = p.code!;
        return [
          const SizedBox(height: 8),
          Center(
            child: Text(
              '${code.substring(0, 3)} ${code.substring(3)}',
              key: const ValueKey('pairing code'),
              style: monoStyle(
                size: 34,
                color: Palette.text,
                weight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(height: 6),
          if (p.step == PairStep.compare) ...[
            Center(child: _small('same number on $who?')),
            // A Wrap: on a narrow phone the two go one above the other.
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 20,
              children: [
                _Link(
                  'match',
                  recording: widget.recording,
                  onTap: () => mode.answer(true),
                ),
                _Link(
                  "doesn't match",
                  recording: widget.recording,
                  onTap: () => mode.answer(false),
                ),
              ],
            ),
          ] else
            Center(child: _small('waiting for $who to tap match…')),
        ];
      case PairStep.connecting:
        return [_small('reaching $who…')];
      case PairStep.idle || PairStep.done || PairStep.failed:
        if (!mode.pairingOpen) {
          return [
            if (p.message != null) _small(p.message!),
            _link('pair a device', _openPairing),
          ];
        }
        final nearby = mode.candidates;
        return [
          if (p.step == PairStep.failed && p.message != null)
            _small(p.message!),
          _small('pairing · $_left · open pair a device on the other one too'),
          if (nearby.isEmpty)
            _small('looking for devices…', color: Palette.faint)
          else
            for (final peer in nearby)
              _link(
                peer.name.isEmpty ? 'a device' : peer.name,
                () => mode.pairWith(peer),
              ),
          _link('stop pairing', mode.closePairing),
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = mode.on;
    final canSwitch = on || mode.canTurnOn;
    final others = mode.others;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 20, color: Palette.line),
        Text(
          'private mode · only your paired devices',
          style: monoStyle(size: 11),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(_label, style: monoStyle(color: Palette.text)),
              ),
              _Toggle(
                label: _label,
                value: on,
                recording: widget.recording,
                onChanged: canSwitch ? _toggle : null,
              ),
            ],
          ),
        ),
        if (!canSwitch)
          _small('pair a device first')
        else if (on)
          _small(
            widget.webShelf
                ? 'only your devices see this one, sealed end to end · '
                      'the web shelf is off: browsers have no key'
                : 'only your devices see this one, sealed end to end',
          ),
        ..._pairing(),
        if (others.isNotEmpty) ...[
          const SizedBox(height: 6),
          _small('your devices', color: Palette.faint),
          for (final m in others)
            Row(
              children: [
                Expanded(
                  child: Text(
                    m.name.isEmpty ? 'a device' : m.name,
                    style: monoStyle(color: Palette.text),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (!_busy)
                  _Link(
                    'forget',
                    recording: widget.recording,
                    onTap: () => _forget(m),
                  ),
              ],
            ),
        ],
        if (mode.circle != null && !_busy) _link('leave circle', _leave),
        if (_note != null) _small(_note!),
      ],
    );
  }
}

const _loginLabel = 'open plop at login';

/// What plop does while its window is closed, which it now outlives on
/// every desktop (in the tray), or while the user is in another app: the
/// one switch for showing arrivals (the island on macOS, Windows and Linux
/// under X11, OS notifications on Wayland: lib/notify.dart), the one for
/// copying arrivals to the clipboard (lib/auto_copy.dart), off unless
/// switched on and saying why, and on Windows and Linux a way to quit from
/// the window, should the tray's menu be out of reach.
class _BackgroundSection extends StatefulWidget {
  const _BackgroundSection(
    this.settings, {
    required this.recording,
    required this.onQuit,
  });
  final Settings settings;

  /// See [_Key.recording].
  final bool recording;

  /// Behind "quit plop"; null hides it.
  final VoidCallback? onQuit;

  @override
  State<_BackgroundSection> createState() => _BackgroundSectionState();
}

class _BackgroundSectionState extends State<_BackgroundSection> {
  static const _notifyLabel = 'show arrivals';
  static const _copyLabel = 'copy arrivals automatically';
  late bool _notify = widget.settings.notifications;
  late bool _copy = widget.settings.autoCopy;

  Widget _switch(String label, bool value, ValueChanged<bool> onChanged) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: monoStyle(color: Palette.text)),
            ),
            _Toggle(
              label: label,
              value: value,
              recording: widget.recording,
              onChanged: onChanged,
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(height: 20, color: Palette.line),
      Text('when plop is in the background', style: monoStyle(size: 11)),
      const SizedBox(height: 6),
      _switch(_notifyLabel, _notify, (on) {
        setState(() => _notify = on);
        widget.settings.notifications = on;
      }),
      _switch(_copyLabel, _copy, (on) {
        setState(() => _copy = on);
        widget.settings.autoCopy = on;
      }),
      // What switching it on lets in, said before anyone does.
      Text(
        'text and pictures from other devices go straight to your '
        'clipboard · anyone nearby can fill it',
        style: monoStyle(size: 11, color: Palette.dim),
      ),
      if (widget.onQuit case final quit?)
        Align(
          alignment: Alignment.centerLeft,
          child: _Link(
            'quit plop · Ctrl+Q',
            recording: widget.recording,
            onTap: quit,
          ),
        ),
    ],
  );
}

/// A hand-drawn on/off switch in the panel's hairline language: 34x18, the
/// track fills with the text colour when on. Material's Switch is 48px tall
/// with a hover halo the theme cannot turn off; this keeps its manners
/// though: Tab reaches it, Space or Enter flips it, a hairline ring shows
/// focus, and assistive tech hears the row's [label].
class _Toggle extends StatefulWidget {
  const _Toggle({
    required this.label,
    required this.value,
    required this.recording,
    required this.onChanged,
  });
  final String label;
  final bool value;

  /// See [_Key.recording]: no flip while a shortcut is being recorded.
  final bool recording;
  final ValueChanged<bool>? onChanged; // null while loading

  @override
  State<_Toggle> createState() => _ToggleState();
}

class _ToggleState extends State<_Toggle> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final enabled = widget.onChanged != null;
    void flip() => widget.onChanged?.call(!value);
    const quick = Duration(milliseconds: 150);
    return Semantics(
      label: widget.label,
      button: true,
      toggled: value,
      enabled: enabled,
      child: Focus(
        canRequestFocus: enabled,
        onFocusChange: (f) => setState(() => _focused = f),
        onKeyEvent: (_, e) {
          if (widget.recording || !_isPress(e)) return KeyEventResult.ignored;
          flip();
          return KeyEventResult.handled;
        },
        child: _Hover(
          enabled: enabled,
          builder: (_, hover) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? flip : null,
            // The padding draws nothing; it makes the target 34x30.
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: _ring(
                focused: _focused,
                radius: 12,
                Opacity(
                  opacity: enabled ? 1 : 0.5,
                  child: AnimatedContainer(
                    duration: quick,
                    width: 34,
                    height: 18,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: value ? Palette.text : Colors.transparent,
                      border: Border.all(
                        color: value
                            ? Palette.text
                            : hover || _focused
                            ? Palette.dim
                            : Palette.border,
                      ),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: AnimatedAlign(
                      duration: quick,
                      alignment: value
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: value ? Palette.bg : Palette.dim,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Click cursor plus a hover flag for the panel's hand-drawn controls.
class _Hover extends StatefulWidget {
  const _Hover({required this.builder, this.enabled = true});
  final Widget Function(BuildContext context, bool hover) builder;
  final bool enabled;

  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: widget.builder(context, _hover && widget.enabled),
  );
}
