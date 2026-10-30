#!/bin/zsh
set -eu
cd "$(dirname "$0")"
APP="${1:-../Codex Orbit.app}"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 5 -O -framework AppKit -framework SwiftUI -lsqlite3 Orbit.swift -o "$APP/Contents/MacOS/CodexOrbit"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexOrbit</string>
<key>CFBundleIdentifier</key><string>local.codex.orbit</string>
<key>CFBundleName</key><string>Codex Orbit</string>
<key>CFBundleDisplayName</key><string>Codex Orbit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
mkdir -p "$APP/Contents/Resources"
if [[ -f whenreset-cache.json ]]; then cp whenreset-cache.json "$APP/Contents/Resources/whenreset-cache.json"; fi
codesign --force --sign - "$APP"
echo "Built: $APP"
