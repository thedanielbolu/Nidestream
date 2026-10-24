#!/usr/bin/env bash
# Renders the store images with headless Chrome:
#   build/store/screenshot-1280x800.png   Chrome Web Store screenshot (also fine for Firefox Add-ons)
#   build/store/promo-440x280.png         Chrome Web Store small promo tile
#   build/store/store-icon-128x128.png    Chrome Web Store store icon
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x "$CHROME" ]] || { echo "Needs Google Chrome in /Applications"; exit 1; }
if [[ ! -f build/icons/AppIcon.iconset/icon_512x512@2x.png ]]; then
  swift scripts/make-icons.swift build/icons >/dev/null
fi

OUT=build/store
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
cp scripts/store-images/*.html "$WORK/"
cp build/icons/AppIcon.iconset/icon_512x512@2x.png "$WORK/icon.png"

render() { # page width height output
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run --user-data-dir="$WORK/profile" \
    --force-device-scale-factor=1 --window-size="$2,$3" --screenshot="$4" "file://$WORK/$1" >/dev/null 2>&1
  echo "› $4"
}
render screenshot.html 1280 800 "$PWD/$OUT/screenshot-1280x800.png"
render promo.html 440 280 "$PWD/$OUT/promo-440x280.png"
cp BrowserExtension/icons/icon128.png "$OUT/store-icon-128x128.png"
echo "› $PWD/$OUT/store-icon-128x128.png"
