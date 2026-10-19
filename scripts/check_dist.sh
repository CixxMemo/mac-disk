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

exit $fail
