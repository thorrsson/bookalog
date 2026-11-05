#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$#" -ne 1 ]; then
  echo "Usage: bash script/build-desktop.sh macos|windows" >&2
  exit 1
fi

case "$1" in
  macos)
    package_extension=dmg
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
    ruby script/package-macos.rb
    ;;
  windows)
    package_extension=msix
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
    (cd app && "${DART_BIN:-dart}" run msix:create \
      --build-windows false --sign-msix false --install-certificate false \
      --output-path ../.cache/desktop --output-name bookalog-windows-unsigned)
    test -s .cache/desktop/bookalog-windows-unsigned.msix
    powershell.exe -NoProfile -NonInteractive -File script/test-windows-package.ps1
    ;;
  *)
    echo "Unsupported desktop target: $1. Choose macos or windows." >&2
    exit 1
    ;;
esac
echo "Unsigned, unconfigured build check: .cache/desktop/bookalog-$1-unsigned.zip"
echo "Unsigned installer package: .cache/desktop/bookalog-$1-unsigned.$package_extension"
echo "Not a signed/notarized or qualified release; no hosted configuration or credentials are embedded."
