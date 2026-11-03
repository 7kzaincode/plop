# plop (app)

The Flutter app for iOS, Android, macOS, Windows and Linux. Install and usage
notes are in [../docs/GUIDE.md](../docs/GUIDE.md); the repo layout, building
from source and the release steps are in
[../docs/DEVELOPING.md](../docs/DEVELOPING.md); the wire protocol is
[../docs/PROTOCOL.md](../docs/PROTOCOL.md).

`flutter test` runs the widget tests (test/layout_test.dart also writes
screenshots to build/screens/); `flutter test integration_test -d macos` runs
the end-to-end test over real Bonjour.
