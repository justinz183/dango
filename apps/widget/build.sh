#!/bin/sh
# Builds the native macOS widget. Usage: apps/widget/build.sh [output path]
# Default output: target/release/shadowcorp-widget (next to the CLI binary).
set -eu
cd "$(dirname "$0")/../.."
out="${1:-target/release/shadowcorp-widget}"
mkdir -p "$(dirname "$out")"
swiftc -O -framework AppKit -o "$out" apps/widget/main.swift
echo "built $out"
