#!/bin/sh
# Build "COGBox.app": the native macOS front end plus the cogbox-mac tool inside the bundle.
# Usage: ./app/build_app.sh
set -eu
cd "$(dirname "$0")/.."

./build.sh
swift build -c release --disable-sandbox --scratch-path build/spm

APP="build/COGBox.app"
# /bin/rm, not rm: rm here is a safe-delete wrapper that moves things to the Trash instead of
# deleting them, so every rebuild left a copy of the old bundle in the user's Trash. This is a
# build artifact inside the project and is regenerated on the next run.
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/Info.plist "$APP/Contents/Info.plist"
cp build/cogbox-mac "$APP/Contents/MacOS/cogbox-mac"
cp build/spm/release/COGBox "$APP/Contents/MacOS/COGBox"

codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/cogbox-mac" >/dev/null 2>&1 || true
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

echo "built: $(pwd)/$APP"
