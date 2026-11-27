#!/bin/bash
# Baut DMS als eigenständige App (DMS.app) und legt sie in den Programme-Ordner.
# Aufruf: ./scripts/build-app.sh            -> /Applications/DMS.app
#         ./scripts/build-app.sh ~/Desktop  -> anderer Zielordner
set -euo pipefail

cd "$(dirname "$0")/.."
TARGET_DIR="${1:-/Applications}"
APP_NAME="DMS"
BUILD_DIR=".build/app"
APP="$BUILD_DIR/$APP_NAME.app"
VERSION="$(git describe --tags --always 2>/dev/null || echo 1.0)"

echo "▶ Baue Release-Version …"
swift build -c release --product DMS
BIN="$(swift build -c release --show-bin-path)/DMS"

echo "▶ Erstelle App-Paket …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# App-Symbol (.icns) aus dem PNG erzeugen
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
SRC="Sources/DMS/Resources/AppIcon.png"
for size in 16 32 128 256 512; do
  sips -z $size $size "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DMS</string>
  <key>CFBundleDisplayName</key><string>DMS</string>
  <key>CFBundleIdentifier</key><string>de.wesseling.dms</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Lokales Datenmanagement</string>
</dict>
</plist>
PLIST

echo "▶ Signiere lokal (ad hoc) …"
codesign --force --deep --sign - "$APP"

echo "▶ Installiere nach $TARGET_DIR …"
mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_DIR/$APP_NAME.app"
cp -R "$APP" "$TARGET_DIR/"
echo "✔ Fertig: $TARGET_DIR/$APP_NAME.app"
