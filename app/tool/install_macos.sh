#!/bin/bash
# Builds plop for this Mac, installs it to /Applications and opens it.
# Run from anywhere: app/tool/install_macos.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# The version settings shows, and the one update checks compare against
# (lib/updates.dart): pubspec's, as a release build of this commit would.
version=$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' pubspec.yaml)
flutter build macos --release --dart-define=PLOP_VERSION="$version"
app=build/macos/Build/Products/Release/plop.app

# Sign with a lasting identity if this Mac has one, so macOS keeps plop's
# Screen Recording and Local Network permissions across updates: first the
# "plop" certificate the downloads are signed with (docs/DEVELOPING.md > Releasing), so
# this build and a downloaded one are the same app to macOS, else your Apple
# Development identity. Without either the build keeps its ad-hoc
# signature, which also works.
ids=$(security find-identity -v -p codesigning)
id=$(awk '/\) [0-9A-F]+ "plop"$/ {print $2; exit}' <<< "$ids")
[ -n "$id" ] || id=$(awk -F'"' '/Apple Development/ {print $2; exit}' <<< "$ids")
if [ -n "$id" ]; then
  find "$app/Contents/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) \
    -exec codesign --force --sign "$id" {} \;
  codesign --force --sign "$id" --entitlements macos/Runner/Release.entitlements "$app"
fi

pkill -x plop 2>/dev/null && sleep 1 || true
rm -rf /Applications/plop.app
cp -R "$app" /Applications/
open /Applications/plop.app
echo "plop installed to /Applications"
