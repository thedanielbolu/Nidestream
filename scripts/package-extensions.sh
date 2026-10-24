#!/usr/bin/env bash
# Builds the store packages for the browser extension from BrowserExtension/:
#   build/extensions/nidestream-chrome-<version>.zip   Chrome Web Store (also Edge, Brave, Opera…)
#   build/extensions/nidestream-firefox-<version>.zip  Firefox Add-ons (addons.mozilla.org)
# BrowserExtension/manifest.json stays the cross-browser one for loading unpacked during development.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/extensions
rm -rf "$OUT"
mkdir -p "$OUT"

for store in chrome firefox; do
  DIR="$OUT/$store"
  mkdir -p "$DIR"
  rsync -a --exclude ".DS_Store" BrowserExtension/ "$DIR/"
  python3 - "$DIR/manifest.json" "$store" <<'EOF'
import json, sys
path, store = sys.argv[1], sys.argv[2]
manifest = json.load(open(path))
if store == "chrome":
    # The Web Store only takes the service worker form, and has no use for Firefox's settings.
    manifest["background"] = {"service_worker": "background.js"}
    manifest.pop("browser_specific_settings", None)
    manifest["minimum_chrome_version"] = "121"
else:
    # Firefox runs MV3 background scripts as an event page, not a service worker.
    manifest["background"] = {"scripts": ["background.js"]}
    manifest["browser_specific_settings"] = {"gecko": {
        "id": "integration@nidestream.app",
        "strict_min_version": "140.0",
        # Everything the extension sends goes to the Nidestream app on the same Mac
        # (127.0.0.1), never to the developer or anyone else.
        "data_collection_permissions": {"required": ["none"]},
    }}
json.dump(manifest, open(path, "w"), indent=2)
open(path, "a").write("\n")
EOF
  VERSION=$(python3 -c "import json; print(json.load(open('$DIR/manifest.json'))['version'])")
  (cd "$DIR" && zip -q -r -X "../nidestream-$store-$VERSION.zip" .)
  echo "› $OUT/nidestream-$store-$VERSION.zip"
done
