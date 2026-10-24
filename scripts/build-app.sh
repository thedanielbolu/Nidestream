#!/usr/bin/env bash
# Builds build/Nidestream.app. Works with just the Command Line Tools (no Xcode needed).
#   scripts/build-app.sh            release build
#   scripts/build-app.sh debug      debug build
#   scripts/build-app.sh --install  release build, then copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --install) INSTALL=1 ;;
  esac
done

source scripts/env.sh

echo "› Building ($CONFIG)…"
swift build -c "$CONFIG" --product Nidestream
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Nidestream"

if [[ ! -f build/icons/AppIcon.icns ]]; then
  echo "› Drawing icons…"
  swift scripts/make-icons.swift build/icons >/dev/null
  iconutil -c icns build/icons/AppIcon.iconset -o build/icons/AppIcon.icns
fi
mkdir -p BrowserExtension/icons
cp build/icons/extension/*.png BrowserExtension/icons/

APP=build/Nidestream.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nidestream"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/icons/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
rsync -a --delete BrowserExtension/ "$APP/Contents/Resources/BrowserExtension/"

# Ad-hoc signature: enough to run locally. Use a Developer ID to distribute.
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "› Built $APP"

if [[ "$INSTALL" == 1 ]]; then
  rm -rf /Applications/Nidestream.app
  cp -R "$APP" /Applications/
  echo "› Installed to /Applications/Nidestream.app"
fi
