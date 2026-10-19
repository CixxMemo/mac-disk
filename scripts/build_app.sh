#!/usr/bin/env bash
# Builds dist/DiskAtlas.app (ad-hoc signed, not notarized) and dist/DiskAtlas.zip.
# Usage: scripts/build_app.sh [VERSION]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
APP="dist/DiskAtlas.app"

swift build -c release --product DiskAtlasApp
BIN="$(swift build -c release --product DiskAtlasApp --show-bin-path)/DiskAtlasApp"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/web"
cp "$BIN" "$APP/Contents/MacOS/DiskAtlas"
cp Resources/web/index.html Resources/web/app.css Resources/web/app.js "$APP/Contents/Resources/web/"
cp Sources/DiskAtlasCore/Resources/rules.json "$APP/Contents/Resources/rules.json"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed "s/{{VERSION}}/$VERSION/g" scripts/Info.plist.template > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --deep --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
# Zip: DiskAtlas/ klasörü içinde .app + OKU-BENI.md (kılavuzdaki sürüm yer tutucusu doldurulur).
PACK="$(mktemp -d)/DiskAtlas"
mkdir -p "$PACK"
ditto "$APP" "$PACK/DiskAtlas.app"
sed "s/{{VERSION}}/$VERSION/g" docs/OKU-BENI.md > "$PACK/OKU-BENI.md"
ZIP="dist/DiskAtlas-$VERSION.zip"
ditto -c -k --norsrc --keepParent "$PACK" "$ZIP"

echo "Hazır: $APP"
echo "Zip:   $ZIP ($(du -h "$ZIP" | cut -f1))"
