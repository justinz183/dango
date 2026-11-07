#!/bin/sh
# Builds Dango.app (the widget as a double-clickable app with an icon).
# Usage: apps/widget/bundle.sh [output .app path]   default: target/release/Dango.app
set -eu
cd "$(dirname "$0")/../.."
app="${1:-target/release/Dango.app}"
version="$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)"

./apps/widget/build.sh target/release/dango-widget >/dev/null
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp target/release/dango-widget "$app/Contents/MacOS/Dango"
# The 团子 art must be clean (transparent, no light rim, 3× its biggest size).
tmpcheck="$(mktemp -d)"
swiftc -O -framework AppKit -o "$tmpcheck/check_art" tools/check_art.swift
"$tmpcheck/check_art" apps/widget/assets
rm -rf "$tmpcheck"
cp -R apps/widget/assets/theme-b "$app/Contents/Resources/theme-b"
cp -R apps/widget/assets/dango "$app/Contents/Resources/dango"
cp -R apps/widget/assets/abti "$app/Contents/Resources/abti"
cp assets/abti.json "$app/Contents/Resources/abti/abti.json"

tmp="$(mktemp -d)"
swiftc -O -framework AppKit -o "$tmp/icon" apps/widget/icon.swift
"$tmp/icon" "$tmp/icon_1024.png" apps/widget/assets/theme-b/logo-dango.png
mkdir "$tmp/Dango.iconset"
for s in 16 32 128 256 512; do
  d=$((s * 2))
  sips -z "$s" "$s" "$tmp/icon_1024.png" --out "$tmp/Dango.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z "$d" "$d" "$tmp/icon_1024.png" --out "$tmp/Dango.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$tmp/Dango.iconset" -o "$app/Contents/Resources/Dango.icns"
rm -rf "$tmp"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Dango</string>
  <key>CFBundleDisplayName</key><string>Dango</string>
  <key>CFBundleIdentifier</key><string>com.dango.widget</string>
  <key>CFBundleExecutable</key><string>Dango</string>
  <key>CFBundleIconFile</key><string>Dango</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "built $app"
