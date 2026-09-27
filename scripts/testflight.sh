#!/bin/sh
# Archive Fuji Bridge and upload it to TestFlight.
#
#   scripts/testflight.sh                  iPhone/iPad and Mac: archive + upload
#   scripts/testflight.sh --archive        both archives, no upload
#   PLATFORMS=ios scripts/testflight.sh    one platform only (ios or mac)
#
# Same target, same sources: the Mac build is Mac Catalyst. Same bundle id, so one App Store Connect record
# covers both (TestFlight lists an iOS build and a macOS build).
#
# Optional App Store Connect API key, instead of the Xcode account:
#   ASC_KEY_ID=XXXX ASC_ISSUER_ID=yyyy ASC_KEY_PATH=~/AuthKey_XXXX.p8 scripts/testflight.sh
#
# The build number is a timestamp so every upload is unique. The version comes from project.yml.
set -eu
cd "$(dirname "$0")/.."

BUILD=$(date +%Y%m%d%H%M)
OUT=build/release

AUTH=""
if [ -n "${ASC_KEY_ID:-}" ]; then
  AUTH="-authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID -authenticationKeyPath $ASC_KEY_PATH"
fi

xcodegen generate
mkdir -p "$OUT"

for PLATFORM in ${PLATFORMS:-ios mac}; do
  case $PLATFORM in
    ios) DEST='generic/platform=iOS' ;;
    mac) DEST='generic/platform=macOS,variant=Mac Catalyst' ;;
    *) echo "Unknown platform $PLATFORM"; exit 1 ;;
  esac
  ARCHIVE=$OUT/FujiBridge-$PLATFORM-$BUILD.xcarchive
  # shellcheck disable=SC2086
  xcodebuild -project FujiBridge.xcodeproj -scheme FujiBridge -configuration Release \
    -destination "$DEST" -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates $AUTH \
    CURRENT_PROJECT_VERSION="$BUILD" archive

  if [ "${1:-}" = "--archive" ]; then
    echo "Archived $ARCHIVE (build $BUILD). Not uploaded."
    continue
  fi

  # shellcheck disable=SC2086
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export-$PLATFORM-$BUILD" \
    -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates $AUTH
  echo "Uploaded $PLATFORM build $BUILD. It shows up in App Store Connect > TestFlight after processing."
done
