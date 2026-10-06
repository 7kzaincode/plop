#!/bin/bash
# Builds plop for this Mac, installs it to /Applications and opens it.
# Run from anywhere: app/tool/install_macos.sh
set -euo pipefail
cd "$(dirname "$0")/.."

flutter build macos --release
app=build/macos/Build/Products/Release/plop.app

# Sign with your Apple Development identity if you have one, so macOS keeps
# plop's Screen Recording and Local Network permissions across updates.
# Without one the build keeps its ad-hoc signature, which also works.
id=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
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
