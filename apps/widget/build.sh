#!/bin/sh
# Builds the native macOS widget. Usage: apps/widget/build.sh [output path]
# Default output: target/release/dango-widget (next to the CLI binary).
# SWIFT_TARGET=arm64-apple-macos13.0 (or x86_64-…) builds for that slice.
set -eu
cd "$(dirname "$0")/../.."
out="${1:-target/release/dango-widget}"
mkdir -p "$(dirname "$out")"
swiftc -O ${SWIFT_TARGET:+-target "$SWIFT_TARGET"} -framework AppKit -o "$out" apps/widget/main.swift apps/widget/theme.swift apps/widget/abti.swift apps/widget/story.swift
echo "built $out"
