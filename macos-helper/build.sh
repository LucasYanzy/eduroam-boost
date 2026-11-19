#!/usr/bin/env bash
# Build eduroam-boost-helper.app (ad-hoc signed). Needs Xcode Command Line Tools (swiftc).
#   ./macos-helper/build.sh [output-dir]      default: ./build
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$HERE/../build}"
APP="$OUT/eduroam-boost-helper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O "$HERE/main.swift" -o "$APP/Contents/MacOS/eduroam-boost-helper" \
  -framework AppKit -framework CoreLocation -framework CoreWLAN
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.lucasyanzy.eduroam-boost.helper</string>
  <key>CFBundleName</key><string>eduroam-boost</string>
  <key>CFBundleDisplayName</key><string>eduroam-boost</string>
  <key>CFBundleExecutable</key><string>eduroam-boost-helper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSLocationUsageDescription</key><string>macOS only shows Wi-Fi network names and access-point addresses to apps with Location access. eduroam-boost uses them to pick the least crowded access point. Your location is never read or stored.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>macOS only shows Wi-Fi network names and access-point addresses to apps with Location access. eduroam-boost uses them to pick the least crowded access point. Your location is never read or stored.</string>
</dict>
</plist>
EOF
/usr/bin/xattr -cr "$APP"
codesign --force --sign - "$APP" >/dev/null
echo "$APP"
