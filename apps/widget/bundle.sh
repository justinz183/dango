#!/bin/sh
# Builds ShadowCorp.app (the widget as a double-clickable app with an icon).
# Usage: apps/widget/bundle.sh [output .app path]   default: target/release/ShadowCorp.app
set -eu
cd "$(dirname "$0")/../.."
app="${1:-target/release/ShadowCorp.app}"
version="$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)"

./apps/widget/build.sh target/release/shadowcorp-widget >/dev/null
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp target/release/shadowcorp-widget "$app/Contents/MacOS/ShadowCorp"

tmp="$(mktemp -d)"
swiftc -O -framework AppKit -o "$tmp/icon" apps/widget/icon.swift
"$tmp/icon" "$tmp/icon_1024.png"
mkdir "$tmp/ShadowCorp.iconset"
for s in 16 32 128 256 512; do
  d=$((s * 2))
  sips -z "$s" "$s" "$tmp/icon_1024.png" --out "$tmp/ShadowCorp.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z "$d" "$d" "$tmp/icon_1024.png" --out "$tmp/ShadowCorp.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$tmp/ShadowCorp.iconset" -o "$app/Contents/Resources/ShadowCorp.icns"
rm -rf "$tmp"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ShadowCorp</string>
  <key>CFBundleDisplayName</key><string>ShadowCorp</string>
  <key>CFBundleIdentifier</key><string>com.shadowcorp.widget</string>
  <key>CFBundleExecutable</key><string>ShadowCorp</string>
  <key>CFBundleIconFile</key><string>ShadowCorp</string>
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
