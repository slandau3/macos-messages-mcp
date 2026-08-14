#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(dirname "$SCRIPT_DIR")"
APP_DIR="$PACKAGE_DIR/outputs/MacOSMessagesMCP.app"

cd "$PACKAGE_DIR"

echo "==> Building release binary"
swift build -c release --product MacOSMessagesMCP
swift build -c release --product MacOSMessagesMCPProxy

BINARY="$PACKAGE_DIR/.build/release/MacOSMessagesMCP"
PROXY_BINARY="$PACKAGE_DIR/.build/release/MacOSMessagesMCPProxy"
if [ ! -f "$BINARY" ] || [ ! -f "$PROXY_BINARY" ]; then
    echo "error: release binary not found at $BINARY" >&2
    exit 1
fi

echo "==> Assembling $APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BINARY" "$APP_DIR/Contents/MacOS/MacOSMessagesMCP"
cp "$PROXY_BINARY" "$APP_DIR/Contents/MacOS/MacOSMessagesMCPProxy"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MacOSMessagesMCP</string>
    <key>CFBundleDisplayName</key>
    <string>MacOSMessagesMCP</string>
    <key>CFBundleIdentifier</key>
    <string>local.macos.messages-mcp</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>MacOSMessagesMCP</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
PLIST

if ! command -v codesign >/dev/null 2>&1; then
    echo "error: codesign is required; refusing to produce an unsigned app" >&2
    exit 1
fi

echo "==> Ad-hoc signing (local identity only, NOT a Developer ID)"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "==> Done: $APP_DIR"
