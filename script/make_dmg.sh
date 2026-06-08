#!/bin/bash
set -e

# Package the built "Unduck Pro.app" into a distributable DMG (drag-to-Applications).
# Run ./script/build_app.sh first so the signed app exists.

APP="Unduck Pro.app"
VOL="Unduck Pro"
STAGING="dist/dmg_staging"

if [ ! -d "$APP" ]; then
  echo "Error: '$APP' not found. Run ./script/build_app.sh first."
  exit 1
fi

# Name the DMG after the app's version, e.g. "Unduck-Pro-2.0.dmg".
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0)"
DMG="dist/Unduck-Pro-${VERSION}.dmg"

echo "Staging DMG contents..."
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING" dist
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "Creating $DMG ..."
hdiutil create -volname "$VOL" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "Done: $DMG"
