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

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE" dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Hifiguard $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
(cd dist && shasum -a 256 "${DMG:t}" | tee "${DMG:t}.sha256")
echo "Built $DMG"
