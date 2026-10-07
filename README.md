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
live. Click its Dock icon, ⌘Tab back to it, or pick "open plop" from its
menu bar icon to bring the window back; ⌘Q or "quit plop" in that menu
quits. Files dropped on the Dock icon land on the shelf. When something
arrives while the window is closed or behind other apps, it drops out of the
notch (from the top of a screen without one) as a black island: what it is,
who sent it, and copy / save right there. Drag the file out of it into any
app, hover to keep it open, or let it tuck itself away after a few seconds;
several from one device show as one, opening into their rows on hover. A
shortcut's result shows there too. It never takes the keyboard from what
you're typing in. The Dock icon keeps a quiet count, without bouncing. The
settings panel can switch the island off ("show arrivals").

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

Closing the window keeps plop running in the tray (next to the clock; at
first Windows may tuck it under the ^ arrow), so the shortcuts and your
items stay live; the first time, a notification says so. Click the tray
icon to bring the window back, right-click it for "quit plop"; Ctrl+Q in the
window or "quit plop" in the settings panel quits too. Its taskbar button
flashes when something arrives while plop is in the background, and a
notification says who sent what (a shortcut's result is one too); click it
to open plop. The settings panel can switch them off. Windows only shows
notifications from apps in the Start menu: the installer's entry covers
that, and a copy from the zip adds itself to your Start menu the first time
it runs (uninstalling plop takes that entry too). Installing an update
closes a running plop first.

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
comes with the desktop, the shortcut, notification and tray libraries with
the tarball. The first launch registers plop with your desktop's launcher, so it
can be pinned and found by search.

Closing the window keeps plop running in the tray, so the shortcuts and your
items stay live; the first time, a notification says so. Click the tray icon
and pick "open plop" to bring the window back, "quit plop" to quit; Ctrl+Q
in the window or "quit plop" in the settings panel quits too. The tray needs
a panel that shows them: KDE and most desktops do, GNOME only with the
AppIndicator extension (on by default on Ubuntu). Started at login, plop
gives the panel 30 seconds to come up; without one, closing the window quits
plop as it used to. A notification says who sent what while plop is in the
background (a shortcut's result is one too); click it to open plop. The
settings panel can switch them off.

The global shortcuts work only in an X11 session. Ubuntu and Debian GNOME log
in to Wayland by default: pick the "… on Xorg" option from the gear menu at
the login screen, or just use the in-window drop and paste (on Wayland the
settings panel says so in place of the shortcut rows). Snipping runs
`gnome-screenshot`, `spectacle` or `scrot`, whichever is installed (`sudo apt
install gnome-screenshot` on stock Ubuntu). If you turned on ufw or
firewalld, allow your LAN subnet in: plop listens on port 7567, or on a
random one if that is taken.

### iPhone and iPad

There is no app download: handing out iOS apps needs a paid Apple Developer
account. Instead, any Mac, Windows or Linux computer running plop serves the
shelf as a web page to every phone on the same Wi-Fi:

1. On the computer, open settings (sliders icon) and find **open on a
   phone**.
2. Point the iPhone's camera at the QR code, or type the address under it
   into Safari: a Mac's `.local` name (like `http://zains-macbook.local:7567/`),
   elsewhere usually an IP address (like `http://192.168.1.20:7567/`).
3. Share > **Add to Home Screen**. From then on plop opens from its own icon,
   full screen.

Tap a row to grab it: text copies, photos open full-screen (touch and hold
to save them to Photos), other files download. `+` adds photos or files,
`paste` adds text, `×` takes back what you added. The page works only while
the computer that serves it is awake with plop running, and the phone does
not count as a device nearby on the other shelves. Android phones can use
the same page; if a `.local` address doesn't open there, use the
`or http://…` one under it.

#### The native app, from source

To build the app itself with a free Apple ID instead, on a Mac with Xcode
and Flutter:

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
  - ⌃⌥G / Ctrl+Shift+Alt+G: grab the newest item from another device (or
    from a phone through the web shelf). Text, pictures and files go on the
    clipboard, ready to paste; a folder saves to Downloads. If you had
    already given ⌃⌥G to one of the others, it starts on ⌃⌥N instead.
  - Change any of them in the settings panel (sliders icon), where you can
    also make plop open at login (macOS 13 or later; if macOS holds the
    switch for approval, the panel says where) and switch off "show
    arrivals" (the island on a Mac, notifications elsewhere).
- **In the background:** closing the window keeps plop running, with an icon
  in the menu bar or tray to bring it back or quit it. Items from other
  devices and the results of the shortcuts then show on the island on a Mac
  (see above), and as OS notifications on Windows and Linux, which open plop
  when clicked; three or more items from one device within a
  couple of seconds are one notification. A text only says how long it is
  ("text · 42 characters"), never what it says, so a copied password stays
  off the lock screen. What the other devices already had when plop started
  isn't announced, nor an item that comes back when its device does.
- **Copy arrivals automatically** (desktop, off unless switched on in the
  settings panel): text and pictures another device plops (or a phone puts
  up through the web shelf) go straight to your clipboard as soon as they
  are here, the newest winning. Files, folders, anything over 25 MB and
  pictures the clipboard can't take as pictures never do (so on Linux only
  text does). Nor does what a device already had: what was there when plop
  started, or what a device brings back after more than a minute away or
  after your computer slept. One that is slow to get here (past its
  download deadline), or that finds you have copied something since it
  arrived, is left on the shelf, so it never overwrites your own copy later
  (on Linux, only a text you copied is noticed), and anything that was
  already up a while before this device saw it (put up while it slept) stays
  on the shelf. Anyone nearby with plop, or with the web shelf open in a
  browser, can fill your clipboard while this is on, which is why it starts
  off.
- **Grab:** tap a row. Text and images copy to the clipboard; files and
  folders save to Downloads (folders unpacked). Hover for the other option;
  tap a saved row again to show it in Finder or Explorer (its folder, on
  Linux). ⌘C / Ctrl+C or Enter grabs the newest item from someone else. On
  phones, files open the share sheet. Images the clipboard can't take as a
  picture save or share instead: all of them on Linux, HEIC, WebP and RAW on
  Windows and Android.
- **Nearby:** the top bar counts the devices plop can reach; hover it (tap
  it on a phone) for their names. With nobody there it says what to check,
  and a device whose firewall keeps plop out shows as unreachable, by
  name: plop on that device says what to allow.
- **Lifetime:** the timer chip in the top bar (30s to 1h), remembered.
- **Big items:** anything over 25 MB is fetched only when someone grabs it, and
  only ever from you, so keep plop open until every device nearby has it (the
  row says so). Smaller items copy to every device as soon as they appear.
  Your own rows say which devices have them. Phones only see the shelf while
  plop is in the foreground; a download cut off by switching away starts
  over by itself once plop is back in front.
- **Phones without the app:** settings › open on a phone has a QR code for
  the web shelf (see iPhone and iPad above).

## From source

Flutter 3.47.6, the version `.github/workflows/ci.yml` pins. Linux also needs
`sudo apt install ninja-build libgtk-3-dev libkeybinder-3.0-dev libnotify-dev
libayatana-appindicator3-dev`. `flutter run` builds run as their own instance, named "… (dev)", so they never wipe the
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
  `bin/plop.dart` is a headless node for testing: `dart run plop_core:plop --text hi --file a.png`
  (`--web` serves the web shelf too, at the addresses it prints).
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
