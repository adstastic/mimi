#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BIN_DIR="$(swift build -c release --show-bin-path)"
EXECUTABLE="$BIN_DIR/Sokki"
APP_DIR="$ROOT_DIR/build/Sokki.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE" "$MACOS_DIR/Sokki"
chmod +x "$MACOS_DIR/Sokki"
cp -R "$ROOT_DIR/Sidecars" "$RESOURCES_DIR/Sidecars"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Sokki</string>
    <key>CFBundleIdentifier</key>
    <string>com.adityam.sokki</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Sokki</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Sokki uses the microphone for local dictation.</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>Sokki uses the Right Command key as a global dictation hotkey.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Sokki uses Apple on-device speech transcription when selected.</string>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${SOKKI_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/{print $2; exit}')"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --deep --timestamp=none --sign "$SIGN_IDENTITY" "$APP_DIR"
  echo "Signed with $SIGN_IDENTITY"
else
  codesign --force --deep --sign - "$APP_DIR"
  echo "Signed ad-hoc; Accessibility permission may reset after rebuilds."
fi

echo "Built $APP_DIR"
