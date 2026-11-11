#!/bin/sh
# Puts a DANGO release together and, with --publish, puts it on GitHub.
#
#   DANGO_RELEASE_URL=https://github.com/justinz183/dango/releases/download/v<version> apps/widget/package.sh
#   (push, and wait for the windows workflow to pass on this commit)
#   tools/release.sh            → target/release-assets, to look at
#   tools/release.sh --publish  → the GitHub release v<version>, with these files:
#
#   Dango-macOS.dmg               the Mac app to drag into Applications (a fixed name, so
#                                 releases/latest/download/Dango-macOS.dmg always works)
#   Dango-Windows-x64-setup.exe   the Windows installer (preview), the same way
#   install.sh                    curl -fsSL https://dangoai.org/install.sh | sh
#   Dango-<version>.zip           what install.sh downloads and checks
#   install.ps1                   irm https://dangoai.org/install.ps1 | iex
#   SHA256SUMS.txt
#
# dangoai.org/install.sh and /install.ps1 are redirects to releases/latest/download/
# (site/_redirects), so the website does not change from one release to the next.
set -eu
cd "$(dirname "$0")/.."
repo=justinz183/dango
version="$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)"
tag="v$version"
base="https://github.com/$repo/releases/download/$tag"
out=target/release-assets
dist=target/dist
rm -rf "$out"
mkdir -p "$out"

# The Mac files, from package.sh; install.sh must point at this release.
for f in "Dango-$version.dmg" "Dango-$version.zip" install.sh; do
  [ -f "$dist/$f" ] || { echo "missing $dist/$f: run DANGO_RELEASE_URL=$base apps/widget/package.sh" >&2; exit 1; }
done
grep -q "BASE=\"\${DANGO_URL:-$base}\"" "$dist/install.sh" || { echo "$dist/install.sh does not point at $base: rebuild with DANGO_RELEASE_URL=$base" >&2; exit 1; }
cp "$dist/Dango-$version.dmg" "$out/Dango-macOS.dmg"
cp "$dist/Dango-$version.zip" "$dist/install.sh" "$out/"

# The Windows installer: the windows workflow's artifact for this very commit. With
# DANGO_WINDOWS_FROM=v<older>, that release's installer and install.ps1 as they are instead:
# Windows stays on the older version while the Mac moves on (user, 2026-11-11: 「windows先不用
# 更新」), and releases/latest/download/ still finds them.
sha="$(git rev-parse HEAD)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM
if [ -n "${DANGO_WINDOWS_FROM:-}" ]; then
  gh release download "$DANGO_WINDOWS_FROM" --repo "$repo" --pattern Dango-Windows-x64-setup.exe --pattern install.ps1 --dir "$out"
  grep -q "releases/download/$DANGO_WINDOWS_FROM'" "$out/install.ps1" || { echo "$DANGO_WINDOWS_FROM's install.ps1 does not download from its own release" >&2; exit 1; }
else
  run="$(gh run list --repo "$repo" --workflow windows.yml --commit "$sha" --status success --limit 1 --json databaseId -q '.[0].databaseId')"
  [ -n "$run" ] || { echo "no passing windows workflow run for $sha yet" >&2; exit 1; }
  gh run download "$run" --repo "$repo" --name Dango-windows-x64 --dir "$tmp"
  exe="$(ls "$tmp"/*.exe | head -1)"
  case "$exe" in *"_${version}_"*) ;; *) echo "the Windows installer is not version $version: $exe" >&2; exit 1 ;; esac
  cp "$exe" "$out/Dango-Windows-x64-setup.exe"
  sum="$(shasum -a 256 "$out/Dango-Windows-x64-setup.exe" | cut -d' ' -f1)"
  sed -e "s|@VERSION@|$version|g" -e "s|@EXE@|Dango-Windows-x64-setup.exe|g" -e "s|@SHA256@|$sum|g" -e "s|@BASE_URL@|$base|g" \
    apps/windows/install.ps1.in > "$out/install.ps1"
fi

(cd "$out" && shasum -a 256 Dango-macOS.dmg "Dango-$version.zip" Dango-Windows-x64-setup.exe install.sh install.ps1 > SHA256SUMS.txt)
cat "$out/SHA256SUMS.txt"

[ "${1:-}" = --publish ] || { echo "assets in $out (add --publish to put them on GitHub as $tag)"; exit 0; }

notes="$tmp/notes.md"
# What changed in this version, if docs/releases/v<version>.md says, comes first.
: > "$notes"
[ -f "docs/releases/$tag.md" ] && { cat "docs/releases/$tag.md"; echo; } >> "$notes"
cat >> "$notes" <<EOF
DANGO turns what your AI does into a team you can see: a little office on your desktop, every step priced at the real U.S. median wage of the person you would hire for it. Works with Claude Code, Codex, DeepSeek and WorkBuddy. Everything is computed on your computer; nothing is uploaded.

## Install

**macOS 13 or later** (Apple silicon and Intel)

- Download: [Dango-macOS.dmg](https://github.com/$repo/releases/latest/download/Dango-macOS.dmg), drag Dango into Applications and open it. The app is not notarized yet, so the first time open System Settings → Privacy & Security and click **Open Anyway**.
- Terminal: \`curl -fsSL https://dangoai.org/install.sh | sh\` (checks the download's SHA-256; no Gatekeeper prompt).

**Windows 10 1803 or later, 64-bit (preview)**

- Download: [Dango-Windows-x64-setup.exe](https://github.com/$repo/releases/latest/download/Dango-Windows-x64-setup.exe). The installer is not signed yet: if SmartScreen stops it, click **More info → Run anyway**. Installs for you only, no administrator rights.
- PowerShell: \`irm https://dangoai.org/install.ps1 | iex\`

**Or ask your AI agent** (Claude Code, Codex…):

> Install DANGO for me. On macOS run \`curl -fsSL https://dangoai.org/install.sh | sh\`; on Windows run \`irm https://dangoai.org/install.ps1 | iex\` in PowerShell. The script checks the download's checksum and opens the app. Then tell me where it was installed and whether Dango is running.

Checksums are in SHA256SUMS.txt.
EOF
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  gh release upload "$tag" --repo "$repo" --clobber "$out"/*
  gh release edit "$tag" --repo "$repo" --notes-file "$notes"
else
  gh release create "$tag" --repo "$repo" --target "$sha" --title "DANGO $version" --notes-file "$notes" "$out"/*
fi
echo "published https://github.com/$repo/releases/tag/$tag"
