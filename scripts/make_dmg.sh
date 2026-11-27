#!/bin/zsh
# Package build/Toolula AI.app as build/ToolulaAI-<version>.dmg (run ./build_app.sh first)
set -e
cd "$(dirname "$0")/.."
APP="build/Toolula AI.app"
[[ -d "$APP" ]] || { echo "Missing $APP, run ./build_app.sh first"; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="build/ToolulaAI-$VER.dmg"
STAGE=$(mktemp -d)
trap '/bin/rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Toolula AI.app"
ln -s /Applications "$STAGE/Applications"
[[ -e "$DMG" ]] && /usr/bin/trash "$DMG"
hdiutil create -volname "Toolula AI $VER" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
echo "built: $DMG ($(du -h "$DMG" | cut -f1))"
