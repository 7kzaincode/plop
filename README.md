# plop

Drop a file, folder, screenshot or text on a shared shelf. Anyone on the same
Wi-Fi with the app open can grab it until its timer runs out (2 minutes by
default). No accounts, no pairing, no picking a recipient.

## Install

> Downloads need the repo to be public (or collaborator access); it is private
> while the first release is being finished.

Downloads are on the [Releases](https://github.com/7kzaincode/plop/releases)
page. They aren't signed by Apple or Microsoft (that needs paid accounts), so
each system warns once; the steps below get past it.

### macOS (12 or later, Apple silicon or Intel; open at login needs 13)

1. Download `plop-macos.dmg`, open it and drag plop to Applications.
2. The first open is blocked ("Apple could not verify plop"): click Done, then
   go to System Settings > Privacy & Security, scroll down and click
   **Open Anyway** next to plop. Or, in Terminal:
   `xattr -dr com.apple.quarantine /Applications/plop.app`.
3. Allow plop to find devices on your local network when asked.
4. The first screen snip (⌃⌥P) asks for Screen Recording. Allow it, then quit
   plop (⌘Q) and open it again: macOS only applies it to a fresh launch. After
   an update macOS treats plop as a new app, so if a snip instead brings plop
   forward saying it isn't allowed yet, open the settings from that message;
   if plop is already switched on there, remove that entry with −, press ⌃⌥P
   again and allow it.

Closing the window keeps plop running, so the shortcuts and your items stay
live. Click its Dock icon or ⌘Tab back to it to bring the window back; ⌘Q
quits. Files dropped on the Dock icon land on the shelf, and when something
arrives while the window is closed or behind other apps the Dock icon shows
a count.

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

Unlike on macOS, closing the window quits plop and stops the shortcuts;
minimize it instead if you want them to stay live. Its taskbar button flashes
when something arrives while plop is in the background.

### Android

Download `plop-android.apk` on the phone and open it. Let your browser install
unknown apps, and pick **Install anyway** if Play Protect warns. From a
computer instead: `adb install -r plop-android.apk`. The APK is signed with a
debug key, not a store key: if Android refuses an update, uninstall plop first.

### Linux (x64, glibc 2.39+: Ubuntu 24.04, Debian 13 or newer)

```sh
sudo apt install avahi-daemon
tar xzf plop-linux-x64.tar.gz && ./plop/plop
```

`avahi-daemon` does discovery and is already running on most desktops; GTK 3
comes with the desktop and the shortcut library with the tarball. The first
launch registers plop with your desktop's launcher, so it can be pinned and
found by search.

The global shortcuts work only in an X11 session. Ubuntu and Debian GNOME log
in to Wayland by default: pick the "… on Xorg" option from the gear menu at
the login screen, or just use the in-window drop and paste (on Wayland the
settings panel says so in place of the shortcut rows). Snipping runs
`gnome-screenshot`, `spectacle` or `scrot`, whichever is installed (`sudo apt
install gnome-screenshot` on stock Ubuntu). Unlike on macOS, closing the
window quits plop and stops the shortcuts; minimize it instead. If you turned
on ufw or firewalld, allow your LAN subnet in: plop listens on a random port.

### iPhone and iPad

There is no download: handing out iOS apps needs a paid Apple Developer
account. Build it from source with a free Apple ID instead, on a Mac with
Xcode and Flutter:

1. Clone this repo, then `cd app && flutter pub get && open ios/Runner.xcworkspace`
   (`pub get` writes the generated Swift package and xcconfig Xcode expects;
   opened without it, Xcode reports a missing FlutterGeneratedPluginSwiftPackage).
   In Xcode, select Runner > Signing & Capabilities and set Team to your Apple
   ID (Add Account… if it isn't listed). If Xcode says the bundle identifier
   is taken, change it to something unique, like `com.yourname.plop`.
2. Connect the iPhone by cable and trust the Mac. Then on the iPhone turn on
   Settings > Privacy & Security > Developer Mode (it restarts).
3. `flutter run --release -d <iPhone>` (`flutter devices` lists it).
4. On the first launch iOS refuses the untrusted developer: go to Settings >
   General > VPN & Device Management, tap your Apple ID and **Trust**. Open
   plop again and allow Local Network.

An app signed with a free Apple ID stops opening after 7 days; repeat step 3
to renew it.

## Using it

- **Add:** drop anything on the window, paste with ⌘V / Ctrl+V, or add files
  with `+` or ⌘O / Ctrl+O. On a Mac, files dropped on plop's Dock icon land
  too. On phones: photo, file, paste; on Android also Share › plop from any
  app.
- **From anywhere (Mac, Windows, Linux on X11):**
  - ⌃⌥P / Ctrl+Shift+Alt+P: select a region of the screen; it lands on plop.
  - ⌃⌥V / Ctrl+Shift+Alt+V: plop whatever is on the clipboard.
  - Change either in the settings panel (sliders icon), where you can also
    make plop open at login (macOS 13 or later; if macOS holds the switch for
    approval, the panel says where).
- **Grab:** tap a row. Text and images copy to the clipboard; files and
  folders save to Downloads (folders unpacked). Hover for the other option;
  tap a saved row again to show it in Finder or Explorer (its folder, on
  Linux). ⌘C / Ctrl+C or Enter grabs the newest item from someone else. On
  phones, files open the share sheet. Images the clipboard can't take as a
  picture save or share instead: all of them on Linux, HEIC, WebP and RAW on
  Windows and Android.
- **Lifetime:** the timer chip in the top bar (30s to 1h), remembered.
- **Big items:** anything over 25 MB is fetched only when someone grabs it, and
  only ever from you, so keep plop open until every device nearby has it (the
  row says so). Smaller items copy to every device as soon as they appear.
  Your own rows say which devices have them. Phones only see the shelf while
  plop is in the foreground.

## From source

Flutter 3.47.6, the version `.github/workflows/ci.yml` pins. Linux also needs
`sudo apt install ninja-build libgtk-3-dev libkeybinder-3.0-dev`. `flutter run`
builds run as their own instance, named "… (dev)", so they never wipe the
installed plop's scratch folders; `PLOP_INSTANCE=x` does the same for a
release build, to run two copies side by side.

- Mac: `app/tool/install_macos.sh` builds a release, signs it with your Apple
  Development identity if you have one (so the Screen Recording and Local
  Network permissions survive rebuilds) and installs it to /Applications.
- Tests: `cd packages/core && dart test`; `cd app && flutter test` (the layout
  test drops screenshots in `app/build/screens/`);
  `flutter test integration_test -d macos` runs the end-to-end test over real
  Bonjour. `flutter analyze` (app) and `dart analyze` (core) are what CI runs
  too.

## Layout

- `packages/core`: protocol, shelf store and sync engine in pure Dart.
  `bin/plop.dart` is a headless node for testing: `dart run plop_core:plop --text hi --file a.png`.
- `app`: the Flutter app (iOS, Android, macOS, Windows, Linux).
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
