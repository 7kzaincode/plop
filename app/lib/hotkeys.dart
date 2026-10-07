import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:plop_core/plop_core.dart';
import 'package:uni_platform/uni_platform.dart';

import 'grab.dart';
import 'notify.dart';
import 'window.dart';

/// System-wide shortcuts on desktop, so things can go on the shelf, and come
/// off it, without switching to plop. The defaults, which the user can
/// rebind:
///   ⌃⌥P / Ctrl+Shift+Alt+P  select a region of the screen; it lands on the shelf
///   ⌃⌥V / Ctrl+Shift+Alt+V  put whatever is on the clipboard on the shelf
///   ⌃⌥G / Ctrl+Shift+Alt+G  grab the newest thing another device put there
/// Windows and Linux add Shift: Ctrl+Alt alone is AltGr on many layouts and
/// clashes with Office and JetBrains shortcuts.
abstract final class Hotkeys {
  static final defaultMods = Platform.isMacOS
      ? const [HotKeyModifier.control, HotKeyModifier.alt]
      : const [
          HotKeyModifier.control,
          HotKeyModifier.shift,
          HotKeyModifier.alt,
        ];
  static final defaultSnip = HotKey(
    key: PhysicalKeyboardKey.keyP,
    modifiers: defaultMods,
  );
  static final defaultClip = HotKey(
    key: PhysicalKeyboardKey.keyV,
    modifiers: defaultMods,
  );

  static final defaultGrab = HotKey(
    key: PhysicalKeyboardKey.keyG,
    modifiers: defaultMods,
  );

  static HotKey snip = defaultSnip;
  static HotKey clip = defaultClip;
  static HotKey grab = defaultGrab;

  static String get snipLabel => label(snip);
  static String get clipLabel => label(clip);
  static String get grabLabel => label(grab);

  /// The current bindings by the name each is saved under
  /// (Settings.hotkey).
  static Map<String, HotKey> get bindings => {
    'snip': snip,
    'clip': clip,
    'grab': grab,
  };

  /// ⌃⌥⇧⌘P on macOS, Ctrl+Shift+Alt+P elsewhere.
  static String label(HotKey k) {
    final mods = k.modifiers ?? const <HotKeyModifier>[];
    final order = Platform.isMacOS
        ? const [
            (HotKeyModifier.control, '⌃'),
            (HotKeyModifier.alt, '⌥'),
            (HotKeyModifier.shift, '⇧'),
            (HotKeyModifier.meta, '⌘'),
          ]
        : const [
            (HotKeyModifier.control, 'Ctrl+'),
            (HotKeyModifier.shift, 'Shift+'),
            (HotKeyModifier.alt, 'Alt+'),
            (HotKeyModifier.meta, 'Win+'),
          ];
    return [
      for (final (m, s) in order)
        if (mods.contains(m)) s,
      keyName(k.physicalKey),
    ].join();
  }

  /// Whether two bindings are the same key with the same modifiers.
  static bool same(HotKey a, HotKey b) =>
      a.physicalKey == b.physicalKey &&
      {...?a.modifiers}.containsAll({...?b.modifiers}) &&
      {...?b.modifiers}.containsAll({...?a.modifiers});

  /// Why [k] must not become a system-wide shortcut, or null if it may. A
  /// key this OS can't bind ([bindable]) never may, function keys included;
  /// otherwise the usual recorder rule: at least one of ⌃ ⌥ ⌘ (Shift alone
  /// would swallow a typed character everywhere), function keys exempt, and
  /// ⌘/Ctrl plus a letter is some app's everyday shortcut (⌘C, ⌘V, Ctrl+Z…).
  static String? reject(HotKey k) {
    final key = k.physicalKey;
    final mods = k.modifiers ?? const <HotKeyModifier>[];
    if (!bindable(key)) {
      return "${keyName(key)} can't be a system-wide shortcut here · "
          'try another key';
    }
    if (isFunctionKey(key)) return null;
    if (!mods.any((m) => m != HotKeyModifier.shift)) {
      final add = Platform.isMacOS ? 'add ⌃ ⌥ or ⌘' : 'add Ctrl, Alt or Win';
      return '$add · ${label(k)} on its own would block typing '
          '${keyName(key)} everywhere';
    }
    final primary = Platform.isMacOS
        ? HotKeyModifier.meta
        : HotKeyModifier.control;
    if (mods.length == 1 && mods.single == primary && _isLetter(key)) {
      return '${label(k)} is an everyday shortcut in other apps · '
          'add another modifier';
    }
    return null;
  }

  /// Whether hotkey_manager can register [key] on this OS, by the code it
  /// sends for it (uni_platform's keyCode, which goes by uni_platform's idea
  /// of the OS; tests set that). Saving a binding it can't would show it as
  /// set, and it would never fire.
  ///
  /// Windows: a key Flutter has no virtual-key code for.
  ///
  /// Linux: keyCode is the first GDK keyval in Flutter's GTK table that
  /// stands for the key, or else its 64-bit logical key id, which the
  /// plugin narrows to a 32-bit guint: ⌃⇧⌥< (the key left of Z on European
  /// keyboards) would bind ⌃⇧⌥Space, media keys nothing. And the first
  /// keyval is sometimes an alias that no key on the keyboard carries, so
  /// keybinder binds nothing and says nothing: the 3270 terminal's
  /// 0xfd00–0xfdff (Enter, Print Screen, Copy, Media Play) and the
  /// keypad's 0xff80–0xffbd (Space as KP_Space, Period as KP_Decimal, F1–F4
  /// as KP_F1–KP_F4), which only the keypad's own keys may have. Letters,
  /// digits and punctuation take the logical id, but theirs are Latin-1
  /// code points, which their keyvals equal.
  static bool bindable(PhysicalKeyboardKey key) {
    final code = key.keyCode;
    return switch (UniPlatform.operatingSystem) {
      'windows' => code != null,
      'linux' =>
        code != null &&
            code <= 0xffffffff &&
            !(code >= 0xfd00 && code <= 0xfdff) &&
            !(code >= 0xff80 && code <= 0xffbd && !_isKeypad(key)),
      _ => true,
    };
  }

  /// The numeric keypad's keys, by USB HID usage: / * - + Enter 1–9 0 . =,
  /// and the rarer ones from the comma on.
  static bool _isKeypad(PhysicalKeyboardKey k) {
    final u = k.usbHidUsage;
    return u >= 0x00070054 && u <= 0x00070063 ||
        u == 0x00070067 ||
        u == 0x00070085 ||
        u >= 0x000700b0 && u <= 0x000700dd;
  }

  /// Whether no other app has [k]. Only Windows can tell: Win32 hot keys are
  /// exclusive, so RegisterHotKey fails on a taken combo, which the plugin
  /// swallows and reports as success. On macOS a combo two apps register
  /// fires in both rather than going dead; X11 fails silently too, but seeing
  /// that would need an X11 probe. Call only while plop's own bindings are
  /// unregistered, or they are what gets found.
  static bool isFree(HotKey k) {
    if (!Platform.isWindows) return true;
    final vk = k.physicalKey.keyCode; // what the plugin registers
    if (vk == null) return true; // unregistrable, not taken; reject() says so
    var mods = 0x4000; // MOD_NOREPEAT
    for (final m in k.modifiers ?? const <HotKeyModifier>[]) {
      mods |= switch (m) {
        HotKeyModifier.alt => 0x1,
        HotKeyModifier.control => 0x2,
        HotKeyModifier.shift => 0x4,
        HotKeyModifier.meta => 0x8,
        _ => 0,
      };
    }
    const id = 0x5050; // far from the plugin's own small ids
    if (_registerHotKey(nullptr, id, mods, vk) == 0) return false;
    _unregisterHotKey(nullptr, id);
    return true;
  }

  static final _user32 = DynamicLibrary.open('user32.dll');
  static final _registerHotKey = _user32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Uint32, Uint32),
        int Function(Pointer<Void>, int, int, int)
      >('RegisterHotKey');
  static final _unregisterHotKey = _user32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)
      >('UnregisterHotKey');

  /// F1–F12, which may stand alone or with any modifier.
  static bool isFunctionKey(PhysicalKeyboardKey k) =>
      k.usbHidUsage >= 0x0007003a && k.usbHidUsage <= 0x00070045;

  static bool _isLetter(PhysicalKeyboardKey k) =>
      k.usbHidUsage >= 0x00070004 && k.usbHidUsage <= 0x0007001d;

  /// A key's printed name from its USB HID usage code. PhysicalKeyboardKey's
  /// debugName is null in release builds, so it can't be used for this.
  static String keyName(PhysicalKeyboardKey key) {
    final u = key.usbHidUsage;
    if (_isLetter(key)) {
      return String.fromCharCode(0x41 + u - 0x00070004); // A-Z
    }
    if (u >= 0x0007001e && u <= 0x00070026) {
      return '${u - 0x0007001e + 1}'; // 1-9
    }
    if (isFunctionKey(key)) return 'F${u - 0x0007003a + 1}';
    return _keyNames[u] ?? '#${(u & 0xffff).toRadixString(16)}';
  }

  static const _keyNames = {
    0x00070027: '0',
    0x00070028: '↩',
    0x0007002a: '⌫',
    0x0007002b: '⇥',
    0x0007002c: 'Space',
    0x0007002d: '-',
    0x0007002e: '=',
    0x0007002f: '[',
    0x00070030: ']',
    0x00070031: r'\',
    0x00070033: ';',
    0x00070034: "'",
    0x00070035: '`',
    0x00070036: ',',
    0x00070037: '.',
    0x00070038: '/',
    0x0007004a: 'Home',
    0x0007004b: 'PgUp',
    0x0007004c: 'Del',
    0x0007004d: 'End',
    0x0007004e: 'PgDn',
    0x0007004f: '→',
    0x00070050: '←',
    0x00070051: '↓',
    0x00070052: '↑',
  };

  static PlopNode? _node;
  static Plopped? _onPlopped;

  /// Global shortcuts only work on X11 under Linux, not Wayland.
  static bool get supported =>
      isDesktop &&
      !(Platform.isLinux &&
          (Platform.environment['XDG_SESSION_TYPE'] == 'wayland' ||
              (Platform.environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty));

  /// The locks [_once] holds: snip and clip share one, so two things never
  /// go on the shelf at once; a grab, which may be a long download, has its
  /// own, so it never keeps the other two waiting.
  static final _busy = <String>{};
  static int _snipGen = 0;
  static final _lastPress = <String, DateTime>{};
  static bool _askedForScreen = false;

  /// hotkey_manager registers without MOD_NOREPEAT on Windows, and keybinder
  /// forwards X11 autorepeat too, so a held chord fires at the keyboard's
  /// repeat rate. Anything within 1.1 s of the previous event of the same
  /// binding is the same press: Windows' initial repeat delay goes up to
  /// 1 s and its slowest rate is 2.5/s. Nobody plops twice within a second.
  static bool _isRepeat(String which) {
    if (Platform.isMacOS) return false;
    final now = DateTime.now();
    final last = _lastPress[which];
    _lastPress[which] = now; // reset on every event: a long hold fires once
    return last != null &&
        now.difference(last) < const Duration(milliseconds: 1100);
  }

  /// [onPlopped] gets a short message after something lands, or with
  /// `ok: false` when it failed and the user needs to act. The shortcuts are
  /// pressed from other apps, so while plop's window is away the message
  /// shows on the island on macOS, or as an OS notification elsewhere
  /// (lib/notify.dart).
  static Future<void> register(PlopNode node, Plopped onPlopped) async {
    _node = node;
    _onPlopped = (message, {ok = true, action, onTap}) {
      Notify.say(message, ok: ok);
      onPlopped(message, ok: ok, action: action, onTap: onTap);
    };
    await apply();
  }

  /// Stops listening, e.g. while the user records a new binding.
  static Future<void> pause() async {
    if (supported) await hotKeyManager.unregisterAll();
  }

  /// (Re)registers the current bindings.
  static Future<void> apply() async {
    final node = _node, onPlopped = _onPlopped;
    if (!supported || node == null || onPlopped == null) return;
    await hotKeyManager.unregisterAll();
    final pressed = <String, void Function()>{
      'snip': () {
        Future<void> run() async {
          final item = await _snipInto(node);
          if (item != null) {
            _feedback(true);
            onPlopped('plopped ${item.name}');
          }
        }

        if (_isRepeat('snip')) return;
        // The Windows snip waits on the user, so it must not hold the lock
        // that the clipboard shortcut shares.
        if (Platform.isWindows) {
          run().catchError((Object e) => _fail(friendlyError(e)));
        } else {
          _once(run);
        }
      },
      'clip': () {
        if (_isRepeat('clip')) return;
        // A Windows snip still waiting on the clipboard would plop this
        // picture a second time, as a screenshot.
        _snipGen++;
        _once(() async {
          if (await pasteInto(node)) {
            _feedback(true);
            onPlopped('plopped clipboard');
          } else {
            _fail('nothing to paste');
          }
        });
      },
      'grab': () {
        if (_isRepeat('grab')) return;
        _once(lock: 'grab', () async {
          final (:message, :saved) = await grabNewest(node);
          _feedback(true);
          onPlopped(
            message,
            action: saved == null ? null : 'show',
            onTap: saved == null ? null : () => reveal(saved),
          );
        });
      },
    };
    // One combo on two bindings fires only the first (and on Windows the
    // second registration fails outright), so the second is left out and
    // said. The recorder refuses a combo another binding has; this is for
    // what comes from elsewhere, a settings file edited by hand, say.
    final held = <String, HotKey>{};
    for (final MapEntry(key: name, value: k) in bindings.entries) {
      if (held.values.any((h) => same(h, k))) {
        onPlopped(
          '${label(k)} is set twice · change one in settings',
          ok: false,
        );
      } else {
        held[name] = k;
      }
    }
    // Registering a taken combo reports success and does nothing, so say so;
    // the other shortcuts still work.
    for (final k in held.values) {
      if (!isFree(k)) {
        onPlopped(
          '${label(k)} is taken by another app · change it in settings',
          ok: false,
        );
      }
    }
    for (final MapEntry(key: name, value: k) in held.entries) {
      await hotKeyManager.register(k, keyDownHandler: (_) => pressed[name]!());
    }
  }

  /// What grab moves to when its default is a combo the user already gave
  /// snip or clip: the first of these neither has. G for grab, then N for
  /// newest; two others can hold at most two of them.
  static final _grabKeys = [
    PhysicalKeyboardKey.keyG,
    PhysicalKeyboardKey.keyN,
    PhysicalKeyboardKey.keyJ,
  ];

  /// Sets the bindings at launch from [saved], what the user recorded
  /// (Settings.hotkey); one never recorded gets its default. Grab came
  /// after the other two, so a user may already have given its default,
  /// ⌃⌥G, to snip or clip; rather than land on top of it, grab then takes
  /// the next of [_grabKeys] neither has, and [remember] is told, so the
  /// panel shows it and it stays put even if the other moves off ⌃⌥G later.
  static void load(
    HotKey? Function(String name) saved, {
    void Function(String name, HotKey k)? remember,
  }) {
    snip = saved('snip') ?? defaultSnip;
    clip = saved('clip') ?? defaultClip;
    if (saved('grab') case final k?) {
      grab = k;
      return;
    }
    grab = [
      for (final key in _grabKeys) HotKey(key: key, modifiers: defaultMods),
    ].firstWhere((k) => !same(k, snip) && !same(k, clip));
    if (!same(grab, defaultGrab)) remember?.call('grab', grab);
  }

  /// Runs [f] unless the same [lock] is held, i.e. a press while the last
  /// one is still running is dropped, not queued; a failure is said.
  static Future<void> _once(
    Future<void> Function() f, {
    String lock = 'shelf',
  }) async {
    if (!_busy.add(lock)) return;
    try {
      await f();
    } catch (e) {
      _fail(friendlyError(e));
    } finally {
      _busy.remove(lock);
    }
  }

  /// The newest item another device put on the shelf, by when this device
  /// first saw it, or null if there is none: what the grab shortcut takes.
  /// Your own are left out, they are here already, but not what a phone
  /// put up through the web shelf ([isUpload]): this device's own items to
  /// the core, but not this user's. Nor one past its expiry, still listed
  /// only while a transfer of it finishes: grabbing it would start a
  /// second, unseen download.
  static ShelfItem? newestRemote(
    Iterable<ShelfItem> items,
    String self, {
    bool Function(String key)? isUpload,
  }) {
    ShelfItem? newest;
    for (final i in items) {
      if (i.originId == self && !(isUpload?.call(i.key) ?? false)) continue;
      if (i.remaining == Duration.zero) continue;
      if (newest == null || i.addedAt.isAfter(newest.addedAt)) newest = i;
    }
    return newest;
  }

  /// What the grab shortcut does with the newest item from another device:
  /// what its row's copy does, since the shortcut is pressed in another app
  /// to paste there. Text, a picture or any other file goes on the
  /// clipboard ([copyItem]); a folder, which the clipboard can't hold as
  /// one, is saved where the row saves it ([saveItem]). Either fetches it
  /// first if it is not here yet. Returns what to say, and where a save
  /// went; throws a [PlopMessage] when there is nothing to grab. [copy] and
  /// [save] are for tests.
  @visibleForTesting
  static Future<({String message, String? saved})> grabNewest(
    PlopNode node, {
    Future<String> Function(PlopNode node, ShelfItem item) copy = copyItem,
    Future<String> Function(PlopNode node, ShelfItem item) save = saveItem,
  }) async {
    final item = newestRemote(node.items, node.id, isUpload: node.web.isUpload);
    if (item == null) throw const PlopMessage('nothing new to grab');
    if (item.kind == ItemKind.folder) {
      final path = await save(node, item);
      return (
        message: 'saved ${item.name} to ${savedWhere(path)}',
        saved: path,
      );
    }
    await copy(node, item);
    return (message: 'copied ${messageName(item)}', saved: null);
  }

  static void _fail(String message) {
    _feedback(false);
    _onPlopped?.call(message, ok: false);
  }

  /// Lets the user drag out a region with the OS's own tool. Returns null if
  /// they cancel.
  static Future<ShelfItem?> _snipInto(PlopNode node) async {
    final name = 'Screenshot ${_dateStamp()}.png';
    final path = '${outDir.path}${Platform.pathSeparator}$name';
    if (Platform.isMacOS) {
      if (!_checkScreenAccess()) return null;
      // -i: interactive region/window selection (space toggles), -x: silent.
      await Process.run('/usr/sbin/screencapture', ['-i', '-x', path]);
      return _addAndDelete(node, path, name);
    }
    if (Platform.isWindows) return _snipWindows(node, name);
    // Linux: the first tool that launches decides; a cancel means stop.
    for (final cmd in [
      ['gnome-screenshot', '-a', '-f', path],
      ['spectacle', '-r', '-b', '-n', '-o', path],
      ['scrot', '-s', path],
    ]) {
      try {
        await Process.run(cmd.first, cmd.sublist(1));
      } on ProcessException {
        continue; // not installed
      }
      return _addAndDelete(node, path, name);
    }
    throw const PlopMessage('install gnome-screenshot, spectacle or scrot');
  }

  /// Owned bytes, so the screenshot is deleted when it expires.
  static Future<ShelfItem?> _addAndDelete(
    PlopNode node,
    String path,
    String name,
  ) async {
    final f = File(path);
    if (!f.existsSync()) return null;
    final bytes = await f.readAsBytes();
    await f.delete();
    return node.addBytes(bytes, name);
  }

  /// Without Screen Recording permission, screencapture silently saves only
  /// the wallpaper and menu bar. False when it is missing, once the user has
  /// been told what to do.
  static bool _checkScreenAccess() {
    final cg = DynamicLibrary.open(
      '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
    );
    bool call(String fn) =>
        cg.lookupFunction<Bool Function(), bool Function()>(fn)();
    if (call('CGPreflightScreenCaptureAccess')) return true;
    // The first request shows the system prompt; later ones return false
    // silently, so the message offers the settings pane instead.
    if (!_askedForScreen) {
      _askedForScreen = true;
      if (call('CGRequestScreenCaptureAccess')) return true;
      _needScreenAccess(
        'allow plop for Screen Recording, then quit plop (⌘Q) and reopen it',
      );
      return false;
    }
    // A switch that is already on usually belongs to an older build of plop,
    // which macOS treats as a different app.
    _needScreenAccess(
      "plop isn't allowed yet · if it's already switched on, remove it with −, "
      'press $snipLabel again, allow it, then reopen plop',
    );
    return false;
  }

  /// The snip was pressed from another app, so the window comes forward
  /// with the steps, which stay until tapped; the tap opens the pane.
  static void _needScreenAccess(String message) {
    _feedback(false);
    MacWindow.show();
    _onPlopped?.call(
      message,
      ok: false,
      action: 'open settings',
      onTap: _openScreenRecordingSettings,
    );
  }

  static void _openScreenRecordingSettings() => Process.run('/usr/bin/open', [
    'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
  ]).ignore();

  /// The Snipping Tool overlay puts its result on the clipboard. Watch the
  /// clipboard's sequence number rather than its contents, so nothing is read
  /// until it changes; a newer press, of this or the clipboard shortcut,
  /// cancels this wait. Esc in the overlay says nothing, so the first
  /// change is taken as the snip unless it is plainly a copy: the overlay
  /// writes a picture and nothing else, while a browser, Office or a text
  /// field adds text or HTML. A picture copied on its own (Paint, Photos,
  /// some chat apps) still can't be told from a snip, which is why the
  /// wait is short: nobody takes 45 s to drag out a rectangle.
  static Future<ShelfItem?> _snipWindows(PlopNode node, String name) async {
    final seqOf = _user32.lookupFunction<Uint32 Function(), int Function()>(
      'GetClipboardSequenceNumber',
    );
    final gen = ++_snipGen;
    final start = seqOf();
    await Process.start('explorer.exe', ['ms-screenclip:']);
    final end = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(end) && gen == _snipGen) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (seqOf() == start) continue;
      // Asked without opening the clipboard, so another process holding it
      // doesn't matter here.
      if (_copyFormats.any((f) => f != 0 && _hasFormat(f) != 0)) return null;
      // Another process may still hold the clipboard for a moment.
      for (var tries = 0; tries < 10; tries++) {
        try {
          final image = await Pasteboard.image;
          if (image == null || image.isEmpty) return null; // not an image
          return await addImageBytes(node, image, prefix: 'Screenshot');
        } on PlatformException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      return null;
    }
    return null;
  }

  static final _hasFormat = _user32
      .lookupFunction<Int32 Function(Uint32), int Function(int)>(
        'IsClipboardFormatAvailable',
      );

  /// What a copy puts on the clipboard and a snip does not: CF_UNICODETEXT,
  /// and the "HTML Format" browsers and Office add, whose id each session
  /// hands out on first use (0 if it could not).
  static final _copyFormats = () {
    final register = _user32
        .lookupFunction<
          Uint32 Function(Pointer<Utf16>),
          int Function(Pointer<Utf16>)
        >('RegisterClipboardFormatW');
    final html = 'HTML Format'.toNativeUtf16();
    try {
      return [13, register(html)];
    } finally {
      malloc.free(html);
    }
  }();

  /// A sound either way: the shortcuts are pressed from other apps, where
  /// the toast in plop's window can't be seen. Fire and forget.
  static void _feedback(bool ok) {
    if (Platform.isMacOS) {
      if (ok) {
        Process.run('/usr/bin/afplay', [
          '/System/Library/Sounds/Pop.aiff',
        ]).ignore();
      } else {
        SystemSound.play(SystemSoundType.alert);
      }
    } else if (Platform.isWindows) {
      // Asterisk is the soft "Background" chime, Hand the "Critical Stop";
      // SystemSound's MB_OK sounds the same as Asterisk on the default scheme.
      _messageBeep(ok ? 0x40 : 0x10);
    } else {
      _playLinux(ok ? 'complete' : 'dialog-error').then((played) {
        if (!played && !ok) SystemSound.play(SystemSoundType.alert);
      });
    }
  }

  static final _messageBeep = _user32
      .lookupFunction<Int32 Function(Uint32), int Function(int)>('MessageBeep');

  /// Plays a freedesktop sound theme event with whichever player is here;
  /// the X11 bell behind SystemSound is muted on most desktops.
  static Future<bool> _playLinux(String event) async {
    final file = '/usr/share/sounds/freedesktop/stereo/$event.oga';
    for (final cmd in [
      ['canberra-gtk-play', '-i', event],
      ['paplay', file],
      ['pw-play', file],
    ]) {
      try {
        if ((await Process.run(cmd.first, cmd.sublist(1))).exitCode == 0) {
          return true;
        }
      } on ProcessException {
        // not installed
      }
    }
    return false;
  }
}

/// How a message names [item]: by its name, but a text only as "text". Its
/// name is its first line, and a copied password or sign-in code would
/// otherwise sit in a notification on the lock screen (see Notify.describe).
String messageName(ShelfItem item) =>
    item.kind == ItemKind.text ? 'text' : item.name;

/// A short message after something lands, or with `ok: false` when it failed
/// and the user needs to act; [action] names what a tap then does.
typedef Plopped = void Function(
  String message, {
  bool ok,
  String? action,
  void Function()? onTap,
});

String _dateStamp() {
  final t = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} at ${stamp()}';
}
