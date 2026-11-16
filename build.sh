#!/bin/zsh
# Build «Шепіт.app» into /Applications/Шепіт.app
set -euo pipefail
cd "${0:A:h}"

APP="/Applications/Шепіт.app"
B="build"
rm -rf "$B"
mkdir -p "$B"

echo "Компіляція Шепіт (Swift + Apple Silicon)…"
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
  Sources/*.swift \
  -o "$B/Shepit" \
  -framework AppKit \
  -framework SwiftUI \
  -framework AVFoundation \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework ApplicationServices \
  -framework ServiceManagement \
  -framework UniformTypeIdentifiers \
  -framework Network \
  -lsqlite3

[[ -x "$B/Shepit" ]]

echo "Генерація іконки AppIcon.icns…"
"$B/Shepit" --icon "$B/icon.png"
mkdir -p "$B/icon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$B/icon.png" --out "$B/icon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$B/icon.png" --out "$B/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$B/icon.iconset" -o "$B/AppIcon.icns"

echo "Пакування $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$B/Shepit" "$APP/Contents/MacOS/Shepit"
cp "$B/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "worker/shepit_worker.py" "$APP/Contents/Resources/shepit_worker.py"
chmod +x "$APP/Contents/MacOS/Shepit" "$APP/Contents/Resources/shepit_worker.py"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Шепіт</string>
  <key>CFBundleDisplayName</key><string>Шепіт</string>
  <key>CFBundleIdentifier</key><string>ua.slava.shepit</string>
  <key>CFBundleExecutable</key><string>Shepit</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Доступ до мікрофона потрібен для голосового диктування у текст.</string>
</dict>
</plist>
EOF

# A stable signing identity keeps macOS permissions (Accessibility, microphone) across rebuilds;
# ad-hoc signatures change on every build and silently drop them.
SIGN_ID="${SHEPIT_SIGN_ID:-}"
if [[ -z "$SIGN_ID" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Kadr Dev"'; then
  SIGN_ID="Kadr Dev"
fi
codesign --force --deep --identifier "ua.slava.shepit" --sign "${SIGN_ID:--}" "$APP"
touch "$APP"
echo "OK → $APP"
