# Building plop

## From source

Flutter 3.47.6 (the version `.github/workflows/ci.yml` pins) and the
toolchain for each system you build for; `flutter doctor` lists anything
missing.

- macOS and iOS: Xcode. The macOS app also needs CocoaPods (`brew install
  cocoapods`): its shortcut and notification plugins are still pods.
- Windows: Visual Studio with the "Desktop development with C++" workload.
- Linux: `sudo apt install clang cmake pkg-config ninja-build libgtk-3-dev
  libkeybinder-3.0-dev libnotify-dev libayatana-appindicator3-dev`.
- Android: Android Studio, which brings the SDK and a JDK.

`flutter run` builds run as their own instance, named "… (dev)", so they
never wipe the installed plop's scratch folders; `PLOP_INSTANCE=x` does the
same for a release build, to run two copies side by side.

- Install on a Mac: `app/tool/install_macos.sh` builds a release, signs it
  with the `plop` certificate from Releasing below if this Mac trusts it for
  code signing, else with your Apple Development identity if you have one
  (so the Screen Recording and Local Network permissions survive rebuilds),
  and installs it to /Applications.
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
- `docs/PROTOCOL.md`: wire protocol.
- `packaging/`: the Windows installer script.

## Releasing

Push a tag: `git tag v0.2.0 && git push origin v0.2.0`.
`.github/workflows/release.yml` builds the downloads above and attaches them
to a GitHub Release for that tag. Running it by hand (Actions > Release > Run
workflow) on a branch replaces a "dev" prerelease instead. Two optional
secrets keep each build recognisable as the same app as the last:

- Android, so each APK installs over the last: your debug keystore,
  `base64 -i ~/.android/debug.keystore | gh secret set ANDROID_DEBUG_KEYSTORE`.
- Mac, so an update keeps plop's Screen Recording permission (Gatekeeper
  still asks for Open Anyway: only a paid account can notarize). Make a
  certificate once in Keychain Access > Certificate Assistant > Create a
  Certificate: name `plop`, Identity Type Self Signed Root, Certificate Type
  Code Signing, tick "Let me override defaults" and make it valid for 3650
  days. Export it with its key from My Certificates as `plop.p12`, with a
  password, then `base64 -i plop.p12 | gh secret set MACOS_SIGN_P12` and
  `gh secret set MACOS_SIGN_P12_PASSWORD`. Keep the .p12: a new certificate
  makes every Mac grant the permission once more. Apple only promises that
  the Local Network permission follows an Apple-issued identity, so macOS
  may still ask for that one after an update. To have
  `app/tool/install_macos.sh` use it too, set the certificate's Trust >
  Code Signing to Always Trust.
