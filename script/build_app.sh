#!/bin/bash
set -e

# Build + package + sign Duck Audio as a proper, double-clickable .app.
#
# THE KEY FIX: we sign with a STABLE self-signed code-signing certificate,
# NOT ad-hoc (`-`). Ad-hoc signatures have an unstable identity that macOS TCC
# refuses to trust, so the mic permission never "takes" and the tap + un-duck
# silently fail when launched from Finder. A stable cert fixes it — the app then
# works double-clicked, exactly like the Terminal `.command` always did.
#
# One-time setup (creates the cert if it doesn't exist): see script/make_cert.sh

CERT="${DUCKAUDIO_SIGN_IDENTITY:-Duck Audio Self Signed}"
APP="Unduck Pro.app"

# Build against the newest RELEASED macOS SDK, not a beta one.
#
# The macOS 27.0 beta SDK redeclares SwiftUI's `State` as a macro, which needs
# the SwiftUIMacros compiler plugin. That plugin ships only with Xcode, so on a
# machine with just the Command Line Tools the app target fails to compile
# ("plugin for module 'SwiftUIMacros' not found"). The 26.x SDK still declares
# `State` as a plain property wrapper and builds fine. The app targets macOS
# 14.2+ regardless, so nothing is lost by not building against the beta.
if [ -z "${SDKROOT:-}" ]; then
  for candidate in "$(xcrun --sdk macosx26 --show-sdk-path 2>/dev/null)" \
                   /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk; do
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then
      export SDKROOT="$candidate"
      break
    fi
  done
fi
echo "Using SDK: ${SDKROOT:-<toolchain default>}"

echo "Building DuckAudioApp (release, universal: arm64 + x86_64)..."
swift build -c release --product DuckAudioApp --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "Packaging $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DuckAudioApp" "$APP/Contents/MacOS/DuckAudio"
cp "assets/UnduckPro.icns" "$APP/Contents/Resources/UnduckPro.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DuckAudio</string>
  <key>CFBundleIdentifier</key><string>dev.mrrockysl.duckaudio</string>
  <key>CFBundleName</key><string>Unduck Pro</string>
  <key>CFBundleDisplayName</key><string>Unduck Pro</string>
  <key>CFBundleIconFile</key><string>UnduckPro</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.3</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Duck Audio needs audio access to keep your media loud during calls.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Duck Audio captures your apps' audio so it can keep it loud during calls.</string>
</dict>
</plist>
PLIST

if ! security find-identity -p codesigning 2>/dev/null | grep -q "$CERT"; then
  echo "WARNING: code-signing identity '$CERT' not found."
  echo "Run script/make_cert.sh once to create it, or set DUCKAUDIO_SIGN_IDENTITY."
  echo "Falling back to ad-hoc (the app will NOT work when double-clicked!)."
  codesign --force --options runtime --sign - --entitlements script/DuckAudio.entitlements "$APP"
else
  echo "Signing with stable identity: $CERT"
  codesign --force --options runtime --sign "$CERT" --entitlements script/DuckAudio.entitlements "$APP"
fi

echo "Architectures: $(lipo -archs "$APP/Contents/MacOS/DuckAudio")"

echo "Registering with LaunchServices..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo "Done. Double-click $APP (or: open $APP)."
echo "First run: grant the microphone prompt. If it was previously denied, run:"
echo "  tccutil reset Microphone dev.mrrockysl.duckaudio"
