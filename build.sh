#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="$ROOT/dist/Local Dictation.app"
BUILD="$ROOT/.build"

if [ -e "$APP" ] && [ "${1-}" != "--replace-build" ]; then
  echo "Build output exists. Review it, then pass --replace-build to replace it." >&2
  exit 2
fi
mkdir -p "$BUILD" "$ROOT/dist"
if [ -e "$APP" ]; then rm -rf "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources/requirements"
cat > "$BUILD/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>LocalDictation</string>
<key>CFBundleIdentifier</key><string>com.gmperkinsmba.fisprwlow</string>
<key>CFBundleName</key><string>Local Dictation</string>
<key>CFBundleDisplayName</key><string>Local Dictation</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Local Dictation records only while you hold your selected dictation shortcut.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>Local Dictation uses Apple Speech only when on-device recognition is available.</string>
</dict></plist>
PLIST
swiftc -parse-as-library -O \
  "$ROOT/Sources/ModelCatalog.swift" \
  "$ROOT/Sources/FisprWlow.swift" \
  -framework AppKit -framework AVFoundation -framework ApplicationServices \
  -framework CoreGraphics -framework Speech \
  -o "$APP/Contents/MacOS/LocalDictation"
cp "$BUILD/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/LocalModelRunner.py" "$APP/Contents/Resources/LocalModelRunner.py"
cp "$ROOT/ModelIntegrity.py" "$APP/Contents/Resources/ModelIntegrity.py"
cp "$ROOT/model-integrity-manifest.json" "$APP/Contents/Resources/model-integrity-manifest.json"
cp "$ROOT/requirements/macos-arm64-py312-speech.lock" "$APP/Contents/Resources/requirements/"
cp "$ROOT/requirements/macos-arm64-py312-cleanup.lock" "$APP/Contents/Resources/requirements/"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
