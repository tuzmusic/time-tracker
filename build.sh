#!/bin/zsh
# Builds TimeTracker.app with plain swiftc (no Xcode project).
# Usage: ./build.sh            -> build/TimeTracker.app
#        ./build.sh install    -> also copies to ~/Applications
set -e
cd "$(dirname "$0")"

APP=build/TimeTracker.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/TimeTracker"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TimeTracker</string>
  <key>CFBundleDisplayName</key><string>Time Tracker</string>
  <key>CFBundleIdentifier</key><string>com.tuzman.timetracker</string>
  <key>CFBundleExecutable</key><string>TimeTracker</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "$1" == "install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/TimeTracker.app
  cp -R "$APP" ~/Applications/
  echo "Installed to ~/Applications/TimeTracker.app"
fi
