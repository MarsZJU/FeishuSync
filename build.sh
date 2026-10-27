#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/build/FeishuSync.app"
MODULE_CACHE="${TMPDIR:-/tmp}/FeishuSync-module-cache"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MODULE_CACHE"
/usr/bin/swiftc -swift-version 5 -O -module-cache-path "$MODULE_CACHE" -target arm64-apple-macosx13.0 Sources/Core.swift Sources/App.swift -o "$APP/Contents/MacOS/FeishuSync" -framework AppKit -framework SwiftUI -framework PDFKit
/usr/bin/swift -module-cache-path "$MODULE_CACHE" Assets/GenerateIcon.swift "$PWD/build/AppIcon.iconset"
/usr/bin/iconutil -c icns "$PWD/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FeishuSync</string>
<key>CFBundleIdentifier</key><string>org.feishusync.desktop</string>
<key>CFBundleName</key><string>FeishuSync</string>
<key>CFBundleDisplayName</key><string>飞书备份</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.0</string>
<key>CFBundleVersion</key><string>9</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# iCloud may add FinderInfo to newly created .app folders; it is not source data.
/usr/bin/xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
# Archive without Finder/iCloud extended attributes for a reproducible portable local build.
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --keepParent "$APP" "$PWD/build/FeishuSync.zip"
echo "Built: $APP"
