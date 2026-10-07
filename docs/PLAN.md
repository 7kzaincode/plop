# Plan

## v1 milestones

1. Toolchain and repo
2. Core package (`packages/core`): shelf store, node server/client, sync engine, tests
3. Desktop app with Bonjour discovery and the one-screen UI
4. Android
5. macOS and iOS
6. Polish: paste, clipboard copy for images/files, expiry animation, icon, device name
7. Packaging: done, unsigned (`.github/workflows/release.yml`; signing only
   when asked)

## Status (2026-10-06)

- Done: core (`dart test` in `packages/core`, 40 tests), the macOS, iOS,
  Android, Windows and Linux apps (`flutter test` in `app`, 54 tests, the
  shelf and layout ones driving a real pair of nodes over loopback), and
  release builds for all but iOS via release.yml (ad-hoc or debug signed;
  the README covers the first open on each system). CI runs the core tests,
  the app's widget tests and the Linux and Windows builds.
- Added beyond the brief: folders, per-item lifetime picker, copy vs save,
  100 GB cap with transfers that outlive expiry, rebindable snip/clipboard
  shortcuts, open at login, Android share target, macOS Dock drops, a Dock
  badge / taskbar flash for arrivals while hidden, a tray / menu bar icon so
  closing the window keeps plop running on every desktop (Ctrl+Q quits from
  the window on Windows and Linux), OS notifications for arrivals and
  shortcut results while the window is away (texts by length only), one-way
  (firewall) peer detection, networking revival after resume, a Windows
  installer that opens the firewall and closes a running plop to upgrade, the frosted macOS window, a Linux launcher entry, receipts
  (a sender's rows say which devices have the item), middle-truncated names
  that keep their tail, and full keyboard operation of the shelf and the
  settings panel (Tab, arrows, Enter, ⌘C).

## After v1

1. **Room code and TLS.** Today anyone on the LAN running the app can grab
   anything on the shelf, and traffic is unencrypted HTTP. Fine at home, not
   elsewhere. Add an optional room code (shared secret that filters peers and
   authenticates requests) and TLS between nodes.
2. Relay server, for networks with client isolation (campus and guest Wi-Fi)
   where device-to-device traffic is blocked.
3. Re-serving mirrors, so an item survives its sender leaving.

## Known limits, by design

- A phone only sees the shelf while the app is in the foreground.
- Networks with client isolation block this entirely.
- No encryption or access control in v1 (see above).
- Global shortcuts are X11-only on Linux; on Wayland the settings panel
  says so in place of the rows (`app/lib/hotkeys.dart`).
- Images don't copy to the clipboard on Linux, and HEIC, WebP and RAW don't
  on Windows or Android; they save or share instead (`app/lib/grab.dart`).
- The Linux tray icon needs a panel that hosts StatusNotifier items (KDE
  does; GNOME with the AppIndicator extension); plop waits up to 30 s after
  launch for one. Without one, closing the window quits plop as it used to,
  so it can never become unreachable. The icon is libayatana-appindicator's
  (shipped in the tarball), and the panel owns clicks on it, so a left click
  opens the menu rather than the window (`app/lib/tray.dart`).
- The Windows tray icon is picked for the light or dark taskbar at launch
  and does not follow a theme change until the next one.
- Open at login needs macOS 13 (SMAppService), which may hold the switch
  until the user approves it in Login Items; the panel says so.
- iOS has no download without a paid Apple account (README).
