#!/usr/bin/env bash
# Build "Ground Control.app" from the Swift package beside this script.
#
#   macos/build.sh             # build + verify → macos/build/Ground Control.app
#   macos/build.sh --install   # …then copy it to ~/Applications
#
# Needs Xcode or the Command Line Tools (Swift 5.9+). The bundle is ad-hoc signed: it runs
# on the Mac that built it, but is not notarized for handing to anyone else.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Ground Control"
BUNDLE_ID="com.launchddash.groundcontrol"
EXECUTABLE="GroundControl"
APP="build/${APP_NAME}.app"

install=0
for arg in "$@"; do
  case "$arg" in
    --install) install=1 ;;
    *) echo "usage: $0 [--install]" >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "build.sh: the app is macOS-only (AppKit + WebKit)" >&2
  exit 1
fi

echo "› swift build (release)"
swift build -c release --product "$EXECUTABLE"
swift build -c release --product GroundControlIcon
bin="$(swift build -c release --show-bin-path)"

echo "› assembling ${APP}"
# Only ever this script's own output folder.
rm -rf "build"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$bin/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp Info.plist "$APP/Contents/Info.plist"

"$bin/GroundControlIcon" build/AppIcon.iconset
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" build/AppIcon.iconset

echo "› signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"

echo "› verifying"
# Each check reads the FINISHED bundle, not the inputs it was made from.
plutil -lint "$APP/Contents/Info.plist" >/dev/null
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "$BUNDLE_ID" ] \
  || { echo "build.sh: bundle identifier is not $BUNDLE_ID" >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")" = "$EXECUTABLE" ] \
  || { echo "build.sh: CFBundleExecutable does not name $EXECUTABLE" >&2; exit 1; }
[ -x "$APP/Contents/MacOS/$EXECUTABLE" ] || { echo "build.sh: executable missing" >&2; exit 1; }
[ -s "$APP/Contents/Resources/AppIcon.icns" ] || { echo "build.sh: icon missing" >&2; exit 1; }
codesign --verify --strict --verbose=1 "$APP"
lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"

echo "Built → macos/${APP}"

if [ "$install" -eq 1 ]; then
  dest="$HOME/Applications/${APP_NAME}.app"
  mkdir -p "$HOME/Applications"
  if [ -e "$dest" ]; then
    # Replace only a previous build of THIS app, never something else by the same name.
    existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$existing" != "$BUNDLE_ID" ]; then
      echo "build.sh: refusing to replace $dest — it is not this app (${existing:-no bundle id})" >&2
      exit 1
    fi
    rm -rf "$dest"
  fi
  ditto "$APP" "$dest"
  echo "Installed → $dest"
  if pgrep -x "$EXECUTABLE" >/dev/null; then
    echo "Ground Control is running: quit it and open it again to use this build."
  fi
fi
