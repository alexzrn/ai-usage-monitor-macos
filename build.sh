#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/AI Usage Monitor.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -parse-as-library "$ROOT/main.swift" -o "$APP/Contents/MacOS/OpenCodeDesk" -framework SwiftUI -framework AppKit
cp "$ROOT/Resources/provider_usage.py" "$APP/Contents/Resources/provider_usage.py"
cp "$ROOT/Resources/registry.json" "$APP/Contents/Resources/registry.json"
mkdir -p "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/ru.lproj" "$APP/Contents/Resources/zh-Hans.lproj"
cp "$ROOT/Resources/en.lproj/Localizable.strings" "$APP/Contents/Resources/en.lproj/Localizable.strings"
cp "$ROOT/Resources/ru.lproj/Localizable.strings" "$APP/Contents/Resources/ru.lproj/Localizable.strings"
cp "$ROOT/Resources/zh-Hans.lproj/Localizable.strings" "$APP/Contents/Resources/zh-Hans.lproj/Localizable.strings"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>OpenCodeDesk</string>
<key>CFBundleIdentifier</key><string>space.soularc.aiusagemonitor</string>
<key>CFBundleName</key><string>AI Usage Monitor</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ru</string><string>zh-Hans</string></array>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Open selected local coding sessions in Terminal.</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
echo "Built: $APP"
