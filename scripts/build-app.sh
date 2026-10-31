#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/app"
swift build -c release --product TouchSampleApp
# TOUCH_SAMPLE_APP_OUT lets scripts/make-installer.sh build into a staging folder.
APP="${TOUCH_SAMPLE_APP_OUT:-$ROOT/dist/Touch Sample.app}"
# The installed app finds the emulator folder through this key (see resolveRoot in main.swift).
ROOT_XML="$(printf '%s' "$ROOT" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/TouchSampleApp" "$APP/Contents/MacOS/TouchSampleApp"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Touch Sample</string>
<key>CFBundleDisplayName</key><string>Touch Sample</string>
<key>CFBundleExecutable</key><string>TouchSampleApp</string>
<key>CFBundleIdentifier</key><string>com.savilion.touchsample</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.7</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>TouchSampleRoot</key><string>$ROOT_XML</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
