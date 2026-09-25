#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIGURATION="${1:-release}"
OUTPUT_ROOT="${AGENT_INJECTION_APP_OUTPUT:-$REPO_ROOT/dist}"
APP="$OUTPUT_ROOT/AgentInjectionIII.app"

cd "$REPO_ROOT"

swift build -c "$CONFIGURATION" --product AgentInjectionIII
swift build -c "$CONFIGURATION" --product injectiond

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p   "$APP/Contents/MacOS"   "$APP/Contents/Helpers"   "$APP/Contents/Resources"

cp "$BIN_DIR/AgentInjectionIII"    "$APP/Contents/MacOS/AgentInjectionIII"
cp "$BIN_DIR/injectiond"    "$APP/Contents/Helpers/injectiond"

chmod +x   "$APP/Contents/MacOS/AgentInjectionIII"   "$APP/Contents/Helpers/injectiond"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>AgentInjectionIII</string>
    <key>CFBundleExecutable</key>
    <string>AgentInjectionIII</string>
    <key>CFBundleIdentifier</key>
    <string>dev.agentinjection.AgentInjectionIII</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AgentInjectionIII</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>AgentInjectionIII connects to DEBUG iOS apps on the local network for code injection and diagnostics.</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"

if command -v codesign >/dev/null 2>&1; then
  codesign     --force     --deep     --sign -     "$APP"
fi

echo
echo "Built clickable menu bar app:"
echo "  $APP"
echo
echo "Open it with:"
echo "  open \"$APP\""
