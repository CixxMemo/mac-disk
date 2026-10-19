#!/usr/bin/env bash
# Verifies dist/ after scripts/build_app.sh. Exit 0 = all checks pass.
set -uo pipefail
cd "$(dirname "$0")/.."
APP="dist/DiskAtlas.app"
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

check "icon file exists" "test -s $APP/Contents/Resources/AppIcon.icns"
check "Info.plist names the icon" "test \"\$(plutil -extract CFBundleIconFile raw $APP/Contents/Info.plist)\" = AppIcon"

check "icon has every size 16..1024" "D=\$(mktemp -d) && iconutil -c iconset $APP/Contents/Resources/AppIcon.icns -o \$D/x.iconset && test \$(ls \$D/x.iconset | wc -l) -eq 10 && sips -g pixelWidth \$D/x.iconset/icon_512x512@2x.png | grep -q 1024"

VERSION="$(plutil -extract CFBundleShortVersionString raw $APP/Contents/Info.plist)"
check "version is 1.0.0" "test \"$VERSION\" = 1.0.0"
ZIP="dist/DiskAtlas-$VERSION.zip"
check "zip name carries the version" "test -s $ZIP"
OUT="$(mktemp -d)"
ditto -x -k "$ZIP" "$OUT" 2>/dev/null
check "zip holds the app and the guide" "test -d $OUT/DiskAtlas/DiskAtlas.app && test -s $OUT/DiskAtlas/OKU-BENI.md"
check "unzipped app keeps a valid signature" "codesign --verify --strict $OUT/DiskAtlas/DiskAtlas.app"
check "unzipped app has the icon" "test -s $OUT/DiskAtlas/DiskAtlas.app/Contents/Resources/AppIcon.icns"
check "guide states the same version" "grep -q \"Sürüm: $VERSION\" $OUT/DiskAtlas/OKU-BENI.md"
check "guide has no unreplaced placeholder" "! grep -q '{{' $OUT/DiskAtlas/OKU-BENI.md"
for text in "Yine de Aç" "xattr -dr com.apple.quarantine" "Tam Disk Erişimi" "Çöp Sepeti" "actions.log" "Tarama bilgisi"; do
  check "guide mentions: $text" "grep -qF \"$text\" $OUT/DiskAtlas/OKU-BENI.md"
done

exit $fail
