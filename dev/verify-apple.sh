#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d /tmp/windowinterp-apple-checks.XXXXXX)
trap 'rm -rf "$CHECK_DIR"' EXIT
xcrun clang -fobjc-arc -O2 -c AppleVTBridge.m -o "$CHECK_DIR/bridge.o"
xcrun swiftc -O -parse-as-library -import-objc-header AppleVTBridge.h \
    AppleInterpolation.swift dev/verify-apple.swift "$CHECK_DIR/bridge.o" \
    -framework VideoToolbox -o "$CHECK_DIR/verify-apple"
"$CHECK_DIR/verify-apple"
