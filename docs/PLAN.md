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

- Done: core (`dart test` in `packages/core`, 67 tests), the macOS, iOS,
  Android, Windows and Linux apps (`flutter test` in `app`, 37 tests, the
  shelf and layout ones driving a real pair of nodes over loopback), and
  release builds for all but iOS via release.yml (ad-hoc or debug signed;
  the README covers the first open on each system). CI runs the core tests,
  the app's widget tests and the Linux and Windows builds.
- Added beyond the brief: folders, per-item lifetime picker, copy vs save,
  100 GB cap with transfers that outlive expiry, rebindable snip/clipboard
  shortcuts, open at login, Android share target, macOS Dock drops, a Dock
  badge / taskbar flash for arrivals while hidden, one-way (firewall) peer
  detection, networking revival after resume, a Windows installer that opens
  the firewall, the frosted macOS window, a Linux launcher entry, receipts
  (a sender's rows say which devices have the item), middle-truncated names
  that keep their tail, and full keyboard operation of the shelf and the
  settings panel (Tab, arrows, Enter, ⌘C).
- Web shelf, for iPhones (no app without a paid Apple account): every
  desktop serves a one-page web app on its own port, 7567 when free and
  remembered, that lists, grabs, uploads and pastes, and installs to the
  home screen. Settings › open on a phone shows its QR code and addresses.
  Other web pages are kept out (a Host allow-list against DNS rebinding, a
  header and Origin check on writes, sandboxed downloads, peer `mime`
  checked), uploads are bounded (4 at once, 8 GB each, 16 GB and 200 items
  in all, 30 s stall timeout), and a browser takes back only what it put up,
  by token. Core tests cover every route over real HTTP; the page itself was
  checked in a desktop browser at phone size against loopback nodes (copy,
  paste sheet, queued uploads, copying rows, remove), not yet on an iPhone.

## After v1

1. **Room code and TLS.** Today anyone on the LAN running the app, or
   opening a desktop's web shelf, can grab anything on the shelf (and,
   through the web shelf, put things on it), and traffic is unencrypted HTTP. Fine at home, not elsewhere. Add an optional
   room code (shared secret that filters peers and authenticates requests)
   and TLS between nodes. TLS would also give the web shelf the share sheet
   and clipboard that browsers keep from plain-HTTP pages.
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
- Only macOS keeps running when the window is closed; Windows and Linux quit
  (no tray icon yet).
- Open at login needs macOS 13 (SMAppService), which may hold the switch
  until the user approves it in Login Items; the panel says so.
- iOS has no app download without a paid Apple account (README); iPhones
  use the web shelf, or build from source.
- The web shelf is plain HTTP, so the page gets no share sheet, clipboard
  API or install prompt: text copies through a selection, images open
  full-screen to save with a long press, other files download. It works only
  while the desktop serving it is up, and a phone on it is not a peer: it
  never shows as nearby or in receipts.
