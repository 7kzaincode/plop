# plop (app)

The Flutter app for iOS, Android, macOS, Windows and Linux. Install and usage
notes, the repo layout, how to build from source and the release steps are in
[../README.md](../README.md); the wire protocol is
[../docs/PROTOCOL.md](../docs/PROTOCOL.md).

`flutter test` runs the widget tests (test/layout_test.dart also writes
screenshots to build/screens/); `flutter test integration_test -d macos` runs
the end-to-end test over real Bonjour.
