#!/bin/zsh
# Builds Hifiguard (Release) and packages it as dist/Hifiguard-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

# Build outside the repo: synced folders like ~/Documents add file attributes that break codesign.
BUILD="${TMPDIR:-/tmp}/hifiguard-build"
xcodebuild -scheme Hifiguard -configuration Release -derivedDataPath "$BUILD" clean build | tail -1

APP="$BUILD/Build/Products/Release/Hifiguard.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE="$BUILD/dmg"
DMG=dist/Hifiguard-$VERSION.dmg

codesign --verify --deep --strict "$APP"

VOLUME="Hifiguard $VERSION"
RW="$BUILD/rw.dmg"

rm -rf "$STAGE" "$DMG" "$RW"
mkdir -p "$STAGE/.background" dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
swift Tools/make-dmg-background.swift "$BUILD/bg" >/dev/null
tiffutil -cathidpicheck "$BUILD/bg/background.png" "$BUILD/bg/background@2x.png" -out "$STAGE/.background/background.tiff" 2>/dev/null

# Lay out the window with Finder on a writable image, then compress it.
hdiutil detach "/Volumes/$VOLUME" -quiet 2>/dev/null || true
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
hdiutil attach "$RW" -noautoopen -quiet
osascript <<OSA
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 860, 548}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "Hifiguard.app" of container window to {180, 230}
        set position of item "Applications" of container window to {480, 230}
        update without registering applications
        delay 1
        close
    end tell
end tell
OSA
sync
hdiutil detach "/Volumes/$VOLUME" -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"
(cd dist && shasum -a 256 "${DMG:t}" | tee "${DMG:t}.sha256")
echo "Built $DMG"
