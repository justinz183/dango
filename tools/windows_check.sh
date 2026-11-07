#!/bin/sh
# Type-checks the Rust crates and the Windows app (apps/windows) for
# Windows on a Mac with no Windows toolchain: `cargo check` for
# x86_64-pc-windows-msvc and -gnu. Build scripts that compile C (SQLite) or
# Windows resources (the app's icon) get stand-ins that write empty objects,
# which is enough because nothing is linked. Building and testing for real
# happens on Windows (.github/workflows/windows.yml).
# Usage: tools/windows_check.sh   (rustup target add x86_64-pc-windows-msvc x86_64-pc-windows-gnu first)
set -eu
cd "$(dirname "$0")/.."
stubs="$(mktemp -d)"
trap 'rm -rf "$stubs"' EXIT

# A C compiler: an empty COFF object wherever -o / -Fo points.
cat > "$stubs/cc" <<'EOF'
#!/bin/sh
out=""; prev=""
for a in "$@"; do
  case "$a" in -Fo*|/Fo*) out="${a#?Fo}";; esac
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
[ -z "$out" ] && exit 0
exec /usr/bin/clang --target=x86_64-pc-windows-gnu -c -x c /dev/null -o "$out"
EOF
# lib.exe: "-out:X objs…" on ar.
cat > "$stubs/lib" <<'EOF'
#!/bin/sh
out=""; objs=""
for a in "$@"; do
  case "$a" in -out:*|-OUT:*|/out:*|/OUT:*) out="${a#*:}";; -*|/*) ;; *) objs="$objs $a";; esac
done
[ -z "$out" ] && exit 0
rm -f "$out"
exec ar crs "$out" $objs
EOF
# llvm-rc: answers its probe, writes an empty .res.
cat > "$stubs/rc" <<'EOF'
#!/bin/sh
out=""; prev=""
for a in "$@"; do
  case "$a" in "/?") printf 'OVERVIEW: Resource Converter (type-check stand-in)\n  /no-preprocess\n'; exit 0;; esac
  case "$prev" in /fo|-fo) out="$a";; esac
  prev="$a"
done
[ -n "$out" ] && : > "$out"
exit 0
EOF
chmod +x "$stubs/cc" "$stubs/lib" "$stubs/rc"

export CC_x86_64_pc_windows_msvc="$stubs/cc" AR_x86_64_pc_windows_msvc="$stubs/lib" RC_x86_64_pc_windows_msvc="$stubs/rc"
export CC_x86_64_pc_windows_gnu="$stubs/cc" AR_x86_64_pc_windows_gnu=ar
# Its own target directory: these objects must never mix with real builds.
export CARGO_TARGET_DIR="${WINDOWS_CHECK_TARGET:-target/windows-check}"

for t in x86_64-pc-windows-msvc x86_64-pc-windows-gnu; do
  echo "== crates, $t"
  cargo check --workspace --all-targets --target "$t"
done
echo "== apps/windows, x86_64-pc-windows-msvc"
# dango.exe is bundled from target/release, which a Mac cannot build.
(cd apps/windows && TAURI_CONFIG='{"bundle":{"resources":null}}' CARGO_TARGET_DIR="../../$CARGO_TARGET_DIR/app" cargo check --all-targets --target x86_64-pc-windows-msvc)
