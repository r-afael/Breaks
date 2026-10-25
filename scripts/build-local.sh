#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild \
  -project Breaks.xcodeproj -scheme Breaks -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/LocalDerivedData \
  PRODUCT_BUNDLE_IDENTIFIER=com.rafael.BreaksOvertime \
  CODE_SIGNING_ALLOWED=NO build
/usr/bin/ditto build/LocalDerivedData/Build/Products/Release/Breaks.app "build/Breaks Overtime.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Breaks Overtime' "build/Breaks Overtime.app/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Breaks Overtime' "build/Breaks Overtime.app/Contents/Info.plist"
# Finder/iCloud can attach these to generated bundles; codesign rejects them.
/usr/bin/xattr -dr com.apple.FinderInfo "build/Breaks Overtime.app" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "build/Breaks Overtime.app" 2>/dev/null || true
/usr/bin/codesign --force --sign - --entitlements Breaks/Breaks.entitlements "build/Breaks Overtime.app"
/usr/bin/codesign --verify --strict "build/Breaks Overtime.app"
