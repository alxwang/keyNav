#!/usr/bin/env bash
# Build, bundle and sign KeyNav.app.
#   ./build.sh           -> build/KeyNav.app
#   ./build.sh install   -> also copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/KeyNav"

APP="build/KeyNav.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/KeyNav"
cp Support/Info.plist "$APP/Contents/Info.plist"

# A stable signing identity keeps Accessibility / Screen Recording grants across rebuilds.
IDENTITY="${KEYNAV_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
if [[ -z "$IDENTITY" ]]; then
  echo "error: no 'Apple Development' signing identity found (set KEYNAV_SIGN_IDENTITY)" >&2
  exit 1
fi
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "Built and signed $APP"

if [[ "${1:-}" == "install" ]]; then
  pkill -x KeyNav 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/KeyNav.app
  cp -R "$APP" /Applications/
  open /Applications/KeyNav.app
  echo "Installed to /Applications/KeyNav.app and launched"
fi
