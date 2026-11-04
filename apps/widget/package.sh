#!/bin/sh
# Builds a Dango.app that carries everything — the widget and the dango
# command, each for Apple silicon and Intel, for macOS 13 and later — and a
# .dmg to hand to someone else. They drag Dango to Applications and open
# it; the first launch sets up the daemon (a LaunchAgent pointing at the
# dango in Contents/Helpers), which imports their Claude Code and Codex history
# and then follows both live, with nothing to install inside either tool.
#
# Usage: apps/widget/package.sh
# Output: target/dist/Dango-<version>.dmg (and target/dist/Dango.app)
#
# The app is signed ad hoc (there is no Developer ID here), so the first
# open needs System Settings → Privacy & Security → Open Anyway; the read-me
# files in the .dmg say so.
set -eu
cd "$(dirname "$0")/../.."
version="$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)"
out=target/dist
work=target/universal
mkdir -p "$out" "$work"

# The dango command, both slices.
export MACOSX_DEPLOYMENT_TARGET=13.0
for t in aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build --release -q -p cli --target "$t"
done
lipo -create -output "$work/dango-cli" target/aarch64-apple-darwin/release/dango target/x86_64-apple-darwin/release/dango

# The widget, both slices.
for a in arm64 x86_64; do
  SWIFT_TARGET="$a-apple-macos13.0" ./apps/widget/build.sh "$work/widget-$a" >/dev/null
done
lipo -create -output "$work/widget" "$work/widget-arm64" "$work/widget-x86_64"

# The app: resources and Info.plist from bundle.sh, then the universal
# binaries in place of the ones it built, then one signature over it all.
# The command goes in Contents/Helpers: in Contents/MacOS, "dango" and the
# app's own "Dango" would be one file (the disk ignores case).
app="$out/Dango.app"
./apps/widget/bundle.sh "$app" >/dev/null
mkdir -p "$app/Contents/Helpers"
cp "$work/widget" "$app/Contents/MacOS/Dango"
cp "$work/dango-cli" "$app/Contents/Helpers/dango"
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

# The disk image: the app, a link to Applications, and how to open it.
stage="$(mktemp -d)"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
cat > "$stage/先读我.txt" <<'EOF'
DONGO（打工团子）

1. 把 Dango 拖进「应用程序」文件夹，然后打开它。
2. 第一次打开时 macOS 可能会说「无法验证开发者」：打开「系统设置 → 隐私与安全性」，往下翻，点「仍要打开」，再打开一次 Dango。
3. 打开以后，团子出现在屏幕右下角。它会先读一遍你电脑上 Claude Code 和 Codex 的历史（~/.claude 和 ~/.codex），读完自动打开「老板人格测试」。之后它在后台跟着记，Claude Code 和 Codex 里什么都不用装。

全部在你的 Mac 上算，什么都不上传。

卸载：右键团子 →「退出」，然后在「终端」里运行
  launchctl bootout gui/$(id -u)/com.dango.daemon
  rm -f ~/Library/LaunchAgents/com.dango.daemon.plist ~/Library/LaunchAgents/com.dango.widget.plist
  rm -rf ~/.dango
最后把「应用程序」里的 Dango 移到废纸篓。
EOF
cat > "$stage/Read Me.txt" <<'EOF'
DONGO (Dango)

1. Drag Dango into the Applications folder, then open it.
2. The first time, macOS may say it can't verify the developer: open System Settings → Privacy & Security, scroll down, click "Open Anyway", and open Dango again.
3. Once it's open, the dango sits in the bottom-right corner of your screen. It first reads your Claude Code and Codex history on this Mac (~/.claude and ~/.codex), then opens the AI Boss Type test by itself. After that it keeps count in the background; there is nothing to install in Claude Code or Codex.

Everything is worked out on your Mac. Nothing is uploaded.

To uninstall: right-click the dango → Quit, then run in Terminal
  launchctl bootout gui/$(id -u)/com.dango.daemon
  rm -f ~/Library/LaunchAgents/com.dango.daemon.plist ~/Library/LaunchAgents/com.dango.widget.plist
  rm -rf ~/.dango
and move Dango from Applications to the Trash.
EOF
dmg="$out/Dango-$version.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "Dango" -srcfolder "$stage" -ov -format UDZO "$dmg"
rm -rf "$stage"
echo "built $dmg"
