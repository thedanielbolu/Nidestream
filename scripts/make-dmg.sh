#!/usr/bin/env bash
# Builds the installer disk image for GitHub Releases:
#   build/Nidestream.dmg            fixed name, so .../releases/latest/download/Nidestream.dmg always works
#   build/Nidestream-<version>.dmg  the same image with the version in its name
# The app is universal (Apple silicon and Intel) and ad-hoc signed, not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh --universal
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Nidestream.app/Contents/Info.plist)

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Nidestream.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to open Nidestream.txt" <<'EOF'
Installing Nidestream

1. Drag Nidestream onto the Applications folder.
2. Open Nidestream from Applications.

The first time, macOS says it can't verify Nidestream, because the app isn't notarized by Apple yet.
To open it anyway:

3. Click Done on that message.
4. Open System Settings > Privacy & Security, scroll down, and click "Open Anyway" next to the
   Nidestream message. Confirm with your Mac's password.

After that it opens normally.

Then add the browser extension (Chrome, Brave, Edge, Firefox): Nidestream shows how when it starts.
EOF

rm -f build/Nidestream.dmg "build/Nidestream-$VERSION.dmg"
hdiutil create -quiet -volname "Nidestream $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov build/Nidestream.dmg
cp build/Nidestream.dmg "build/Nidestream-$VERSION.dmg"
echo "› build/Nidestream.dmg ($(du -h build/Nidestream.dmg | cut -f1 | tr -d ' '), version $VERSION)"
