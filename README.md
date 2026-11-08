<p align="center">
  <img src="site/logo.png" width="72" alt="plop">
</p>

<h1 align="center">plop</h1>

<p align="center">
  Drop it on the shelf. Grab it on any device nearby.<br>
  <a href="https://github.com/7kzaincode/plop/releases/latest">Download</a> ·
  <a href="docs/GUIDE.md">Guide</a> ·
  <a href="docs/PROTOCOL.md">Protocol</a>
</p>

---

plop is a shared shelf for every device on your Wi-Fi. Put a file, folder,
screenshot or some text on it, and every other device can grab it for the
next two minutes.

No accounts. No cloud. No pairing. Files go straight from one device to
another over your local network. The one thing plop asks of the internet
is whether GitHub has a newer version, twice a day, which settings can
switch off; "update to …" there installs it.

## Features

- **Every platform:** Mac, Windows, Linux and Android. iPhone and iPad work
  through the browser, with no install, at `http://plop.local:7567` on
  whichever of your computers is on. The page offers a **Send to plop**
  Shortcut, which puts plop in every app's share menu.
- **Snip to the shelf:** `⌃⌥P` puts any part of your screen on plop. `⌃⌥V`
  plops your clipboard.
- **Grab the newest:** `⌃⌥G` copies the last thing another device sent.
- **The island:** on a Mac, arrivals drop out of the notch with copy and save
  buttons. Drag the file straight out of it.
- **Runs quietly:** close the window and plop stays in the menu bar or tray.
- **Any size:** small items copy instantly. Big ones, up to 100 GB, are
  fetched when you grab them.
- **Private mode:** pair your own devices once (compare a six-digit number)
  and only they see each other, with every transfer encrypted.

## Install

| System | Download |
| --- | --- |
| macOS 12+ | [`plop-macos.dmg`](https://github.com/7kzaincode/plop/releases/latest/download/plop-macos.dmg) |
| Windows 10 / 11 | [`plop-windows-setup.exe`](https://github.com/7kzaincode/plop/releases/latest/download/plop-windows-setup.exe) |
| Linux (x64) | [`plop-linux-x64.tar.gz`](https://github.com/7kzaincode/plop/releases/latest/download/plop-linux-x64.tar.gz) |
| Android | [`plop-android.apk`](https://github.com/7kzaincode/plop/releases/latest/download/plop-android.apk) |
| iPhone / iPad | Open plop on a computer › settings › scan the QR code |

plop isn't signed by Apple or Microsoft yet, so each system warns once on
first open. On a Mac, go to **System Settings › Privacy & Security › Open
Anyway**. On Windows, click **More info › Run anyway**. The
[guide](docs/GUIDE.md) has the full steps for each system.

## How it works

Each device running plop announces itself on the local network (mDNS) and
serves its shelf over plain HTTP. The others list it, copy small items right
away, and fetch big ones on demand. Every item has a timer, and when it runs
out the item is gone from every device. Files never leave your network. The
details are in [PROTOCOL.md](docs/PROTOCOL.md).

## Build from source

Flutter 3.47.6. See [DEVELOPING.md](docs/DEVELOPING.md).

```sh
cd app && flutter run
```

## Credits

Built by [@7kzaincode](https://github.com/7kzaincode), with
[Claude](https://claude.com/claude-code) as a contributor.

## License

[MIT](LICENSE)
