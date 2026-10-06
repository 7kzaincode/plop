# plop

Drop a file, folder, screenshot or text on a shared shelf. Anyone on the same
Wi-Fi with the app open can grab it until its timer runs out (2 minutes by
default). No accounts, no pairing, no picking a recipient.

## Install

Downloads are on the [Releases](https://github.com/7kzaincode/plop/releases)
page. They aren't signed by Apple or Microsoft (that needs paid accounts), so
each system warns once; the steps below get past it.

### macOS (12 or later, Apple silicon or Intel)

1. Download `plop-macos.dmg`, open it and drag plop to Applications.
2. The first open is blocked ("Apple could not verify plop"): click Done, then
   go to System Settings > Privacy & Security, scroll down and click
   **Open Anyway** next to plop. Or, in Terminal:
   `xattr -dr com.apple.quarantine /Applications/plop.app`.
3. Allow plop to find devices on your local network when asked.

Closing the window keeps plop running, so the shortcuts and your items stay
live. Click its Dock icon to bring the window back; ⌘Q quits.

### Windows (10 or 11)

1. Download and run `plop-windows-setup.exe`. SmartScreen says "Windows
   protected your PC": click **More info**, then **Run anyway**. (With Smart
   App Control on, Windows blocks unsigned apps with no way past.)
2. Accept the admin prompt. The installer adds a firewall rule so the other
   devices can reach this PC; without it they see the PC but can't grab from it.

No installer: unzip `plop-windows-x64.zip` and run `plop.exe`. When Windows
Firewall asks, tick both Private and Public. If you clicked Cancel, remove the
plop entries under Windows Security > Firewall & network protection > Allow an
app through firewall (or run the installer, which clears them).

### Android

Download `plop-android.apk` on the phone and open it. Let your browser install
unknown apps, and pick **Install anyway** if Play Protect warns. From a
computer instead: `adb install -r plop-android.apk`. The APK is signed with a
debug key, not a store key: if Android refuses an update, uninstall plop first.

### Linux (x64, glibc 2.39+: Ubuntu 24.04, Debian 13 or newer)

```sh
sudo apt install avahi-daemon libkeybinder-3.0-0
tar xzf plop-linux-x64.tar.gz && ./plop/plop
```

`avahi-daemon` does discovery, `libkeybinder-3.0` the global shortcuts (GTK 3
comes with the desktop). Building from source also needs
`libkeybinder-3.0-dev`.

### iPhone and iPad

There is no download: handing out iOS apps needs a paid Apple Developer
account. Build it from source with a free Apple ID instead, on a Mac with
Xcode and Flutter:

1. Clone this repo, then `cd app && open ios/Runner.xcworkspace`. In Xcode,
   select Runner > Signing & Capabilities and set Team to your Apple ID
   (Add Account… if it isn't listed). If Xcode says the bundle identifier is
   taken, change it to something unique, like `com.yourname.plop`.
2. Connect the iPhone by cable and trust the Mac. Then on the iPhone turn on
   Settings > Privacy & Security > Developer Mode (it restarts).
3. `flutter run --release -d <iPhone>` (`flutter devices` lists it).
4. On the first launch iOS refuses the untrusted developer: go to Settings >
   General > VPN & Device Management, tap your Apple ID and **Trust**. Open
   plop again and allow Local Network.

An app signed with a free Apple ID stops opening after 7 days; repeat step 3
to renew it.

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

## Layout

- `packages/core`: protocol, shelf store and sync engine in pure Dart (`dart test`).
  `bin/plop.dart` is a headless node for testing: `dart run plop_core:plop --text hi --file a.png`.
- `app`: the Flutter app (iOS, Android, macOS, Windows, Linux).
  `flutter test integration_test -d macos` runs an end-to-end test over real Bonjour.
- `docs/PROTOCOL.md`: wire protocol. `docs/PLAN.md`: milestones and what comes after v1.
- `packaging/`: the Windows installer script.

## Releasing

Push a tag: `git tag v0.2.0 && git push origin v0.2.0`.
`.github/workflows/release.yml` builds the downloads above and attaches them
to a GitHub Release for that tag. Running it by hand (Actions > Release > Run
workflow) on a branch replaces a "dev" prerelease instead. Optional: to keep
the APK's signature the same from build to build, so each one installs over
the last, add your debug keystore as a secret:
`base64 -i ~/.android/debug.keystore | gh secret set ANDROID_DEBUG_KEYSTORE`.
