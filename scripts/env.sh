# Shared build settings, sourced by the other scripts.
#
# With only the Command Line Tools installed, the newest macOS SDK expects SwiftUI's macro plugin,
# which ships with Xcode alone. Fall back to the newest SDK that still works without it.
if ! xcode-select -p 2>/dev/null | grep -q "Xcode"; then
  CLT=/Library/Developer/CommandLineTools
  for sdk in "$CLT"/SDKs/MacOSX26.5.sdk "$CLT"/SDKs/MacOSX26.sdk "$CLT"/SDKs/MacOSX15.sdk; do
    if [[ -d "$sdk" ]]; then
      export SDKROOT="$sdk"
      break
    fi
  done
  TESTING_PLUGINS="$CLT/usr/lib/swift/host/plugins/testing"
fi
