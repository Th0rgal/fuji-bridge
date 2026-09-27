#!/bin/zsh
# Build the Debug app, boot the simulators in a clean state and give every target the same demo library.
#   tools/store/stage.sh
set -e
source "$(dirname "$0")/lib.sh"
cd $REPO
xcodegen generate >/dev/null

# The demo photos: people-free frames from the real library (see docs/STORE.md), copied, never moved.
mkdir -p "$DEMO"
while read f; do cp -n "$LIBRARY/$f" "$DEMO/" 2>/dev/null || true; done < tools/store/demo-photos.txt

xcodebuild -project FujiBridge.xcodeproj -scheme FujiBridge -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath build/mac build >/dev/null
for D in $IPHONE $IPAD; do
  xcrun simctl boot $D 2>/dev/null || true
  xcodebuild -project FujiBridge.xcodeproj -scheme FujiBridge -destination "id=$D" -derivedDataPath build/shots build >/dev/null
  xcrun simctl install $D "$(find build/shots -name FujiBridge.app -path '*iphonesimulator*' | head -1)"
  xcrun simctl ui $D appearance dark
  xcrun simctl status_bar $D override --time "9:41" --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 --dataNetwork wifi
  C=$(xcrun simctl get_app_container $D $BUNDLE data)
  mkdir -p "$C/Documents/Fuji Bridge"
  cp "$DEMO"/*.JPG "$C/Documents/Fuji Bridge/"
done
echo "staged: iPhone $IPHONE, iPad $IPAD, Mac $MAC_APP"
