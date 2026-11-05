#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 1 ]; then
  echo "Usage: bash script/build-desktop.sh macos|windows" >&2
  exit 1
fi

case "$1" in
  macos)
    if [ "$(uname -s)" != Darwin ]; then
      echo "The macOS build requires a macOS host with Xcode." >&2
      exit 1
    fi
    for entitlement in app/macos/Runner/DebugProfile.entitlements app/macos/Runner/Release.entitlements; do
      plutil -lint "$entitlement"
      if [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.files.user-selected.read-write' "$entitlement")" != true ]; then
        echo "Native file exchange requires the user-selected read/write entitlement." >&2
        exit 1
      fi
    done
    (cd app && CODE_SIGNING_ALLOWED=NO "${FLUTTER_BIN:-flutter}" build macos --release)
    bundle="app/build/macos/Build/Products/Release/Bookalog Catalog.app"
    test -x "$bundle/Contents/MacOS/Bookalog Catalog"
    if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$bundle/Contents/Info.plist")" != "Bookalog Catalog" ]; then
      echo "The macOS bundle must display the Bookalog Catalog product name." >&2
      exit 1
    fi
    mkdir -p .cache/desktop
    ditto -c -k --sequesterRsrc --keepParent \
      "$bundle" \
      .cache/desktop/bookalog-macos-unsigned.zip
    ;;
  windows)
    case "$(uname -s)" in
      MINGW*|MSYS*) ;;
      *) echo "The Windows build requires Git Bash on Windows with Visual Studio C++ tools." >&2; exit 1 ;;
    esac
    (cd app && "${FLUTTER_BIN:-flutter}" build windows --release)
    test -f app/build/windows/x64/runner/Release/bookalog_catalog.exe
    if ! command -v 7z >/dev/null; then
      echo "Windows packaging requires 7-Zip (7z) on PATH." >&2
      exit 1
    fi
    mkdir -p .cache/desktop
    archive="$PWD/.cache/desktop/bookalog-windows-unsigned.zip"
    rm -f .cache/desktop/bookalog-windows-unsigned.zip
    (cd app/build/windows/x64/runner/Release && 7z a -tzip "$archive" .)
    test -s "$archive"
    ;;
  *)
    echo "Unsupported desktop target: $1. Choose macos or windows." >&2
    exit 1
    ;;
esac
echo "Unsigned, unconfigured build check: .cache/desktop/bookalog-$1-unsigned.zip"
echo "Not a signed installer or a qualified release; no hosted configuration or credentials are embedded."
