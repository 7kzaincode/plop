import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'hotkeys.dart';
import 'login_item.dart';
import 'settings.dart';
import 'theme.dart';

/// The one settings surface: global shortcuts and open-at-login.
Future<void> showSettings(BuildContext context, Settings settings) =>
    showDialog<void>(
      context: context,
      barrierColor: const Color(0x99000000),
      builder: (_) => _SettingsPanel(settings),
    );

class _SettingsPanel extends StatefulWidget {
  const _SettingsPanel(this.settings);
  final Settings settings;

  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel> {
  String? _recording; // 'snip' or 'clip'
  String? _note;
  bool? _login;

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
    super.dispose();
  }

  void _record(String which) {
    _stopRecording(apply: false);
    Hotkeys.pause();
    HardwareKeyboard.instance.addHandler(_onKey);
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
    final other = _recording == 'snip' ? Hotkeys.clip : Hotkeys.snip;
    if (Hotkeys.same(k, other)) {
      setState(() => _note = 'that one is already taken');
      return true;
    }
    if (!Hotkeys.isFree(k)) {
      setState(() => _note = 'another app already uses ${Hotkeys.label(k)}');
      return true;
    }
    final which = _recording!;
    if (which == 'snip') {
      Hotkeys.snip = k;
    } else {
      Hotkeys.clip = k;
    }
    // Leave recording mode and re-register first, so a failure while saving
    // can never strand the panel on "…" with the shortcuts paused.
    _stopRecording(apply: true);
    setState(() => _note = null);
    try {
      widget.settings.setHotkey(which, k);
    } catch (_) {
      setState(() => _note = "couldn't save that · it works until plop quits");
    }
    return true;
  }

  void _reset() {
    _stopRecording(apply: false);
    Hotkeys.snip = Hotkeys.defaultSnip;
    Hotkeys.clip = Hotkeys.defaultClip;
    widget.settings
      ..setHotkey('snip', null)
      ..setHotkey('clip', null);
    Hotkeys.apply();
    setState(() => _note = null);
  }

  Future<void> _toggleLogin(bool on) async {
    final now = await LoginItem.set(on);
    if (!mounted) return;
    setState(() {
      _login = now;
      if (now != on) _note = "couldn't change that here";
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = monoStyle(color: Palette.text);
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
        child: Padding(
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
                    onTap: () => _record('snip'),
                  ),
                  label,
                ),
                _row(
                  'plop the clipboard',
                  _Key(
                    text: _recording == 'clip' ? '…' : Hotkeys.clipLabel,
                    active: _recording == 'clip',
                    onTap: () => _record('clip'),
                  ),
                  label,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _reset,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 28),
                      foregroundColor: Palette.dim,
                    ),
                    child: Text(
                      'reset to defaults',
                      style: monoStyle(size: 11),
                    ),
                  ),
                ),
                const Divider(height: 20, color: Palette.line),
              ],
              if (LoginItem.supported)
                _row(
                  'open plop at login',
                  Switch(
                    value: _login ?? false,
                    onChanged: _login == null ? null : _toggleLogin,
                    activeTrackColor: Palette.text,
                    activeThumbColor: Palette.bg,
                    inactiveTrackColor: const Color(0xFF2A2A2A),
                    inactiveThumbColor: Palette.dim,
                    trackOutlineColor: const WidgetStatePropertyAll(
                      Colors.transparent,
                    ),
                  ),
                  label,
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

/// A key-combo button that records a new binding when clicked.
class _Key extends StatelessWidget {
  const _Key({required this.text, required this.active, required this.onTap});
  final String text;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 64),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? const Color(0x1FFFFFFF) : null,
          border: Border.all(color: active ? Palette.text : Palette.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: monoStyle(color: Palette.text),
        ),
      ),
    ),
  );
}
