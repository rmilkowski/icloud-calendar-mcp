#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Keep caches in the project; no account credentials or network dependencies needed.
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/swift-cache}"
# Nested sandbox-exec is unavailable in some managed development environments.
# The outer development environment still enforces its own filesystem permissions.
swift build --disable-sandbox
BINARY_DIR=$(swift build --disable-sandbox --show-bin-path)
APP="$PWD/build/Calendar MCP Helper.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY_DIR/CalendarHelper" "$APP/Contents/MacOS/CalendarHelper"
cp packaging/Info.plist "$APP/Contents/Info.plist"
SIGNING_IDENTITY="${CALENDAR_SIGNING_IDENTITY:--}"
if [ "$SIGNING_IDENTITY" = "-" ]; then
    printf '%s\n' 'Development ad-hoc signature only; use a stable CALENDAR_SIGNING_IDENTITY for durable TCC attribution. Live permission behavior is unverified.' >&2
    codesign --force --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
printf 'Built %s\n' "$APP"
