# plop

Drop a file, folder, screenshot or text on a shared shelf. Anyone on the same
Wi-Fi with the app open can grab it until its timer runs out (2 minutes by
default). No accounts, no pairing, no picking a recipient.

## Using it

- **Add:** drop anything on the window, paste with ⌘V / Ctrl+V, or use `+`.
  On phones: photo, file, paste.
- **From anywhere (Mac, Windows, Linux):**
  - ⌃⌥P / Ctrl+Alt+P: select a region of the screen; it lands on plop.
  - ⌃⌥V / Ctrl+Alt+V: plop whatever is on the clipboard.
- **Grab:** tap a row. Text and images copy to the clipboard; files and
  folders save to Downloads (folders unpacked). Hover for the other option.
  On phones, files open the share sheet.
- **Lifetime:** the timer chip in the top bar (30s to 1h), remembered.

## Linux

Needs `avahi-daemon` (discovery) and `libkeybinder-3.0` (global shortcuts):
`sudo apt install avahi-daemon libkeybinder-3.0-0`. Building also needs
`libkeybinder-3.0-dev`.

## Layout

- `packages/core`: protocol, shelf store and sync engine in pure Dart (`dart test`).
  `bin/plop.dart` is a headless node for testing: `dart run plop_core:plop --text hi --file a.png`.
- `app`: the Flutter app (iOS, Android, macOS, Windows, Linux).
  `flutter test integration_test -d macos` runs an end-to-end test over real Bonjour.
- `docs/PROTOCOL.md`: wire protocol. `docs/PLAN.md`: milestones and what comes after v1.
