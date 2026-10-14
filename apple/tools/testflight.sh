#!/usr/bin/env bash
# Archives SamRabbit for iPhone (with the Apple Watch app inside) and uploads it to App Store Connect for TestFlight.
#
#   apple/tools/testflight.sh              archive + upload
#   apple/tools/testflight.sh --archive    archive only (prints the .xcarchive path)
#   apple/tools/testflight.sh --upload A   upload an existing archive A
#
# Needs: Xcode signed in to the team's Apple ID (Xcode > Settings > Accounts), apple/Config/Signing.local.xcconfig
# (see Signing.xcconfig), and the app record com.samrabbit.mobile on App Store Connect. Xcode signs for distribution
# itself (cloud-managed certificates, -allowProvisioningUpdates). The build number is the UTC time (yyyymmddHHMM), so
# every upload is newer than the last one; the version stays MARKETING_VERSION from project.yml.
set -euo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
TEAM=$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' "$HERE/Config/Signing.local.xcconfig" 2>/dev/null | head -1)
OUT="$HERE/build/testflight"
mode=all
archive=
case "${1:-}" in
  --archive) mode=archive ;;
  --upload) mode=upload; archive=${2:?usage: testflight.sh --upload <archive>} ;;
  -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
  "") ;;
  *) echo "testflight.sh: unknown option $1" >&2; exit 64 ;;
esac
mkdir -p "$OUT"

# App Store Connect rejects a build whose App Intent descriptions contain Apple trademarks such as "Mac" (ITMS 90626).
if grep -rniE 'IntentDescription\(.*\b(mac|iphone|ipad|siri|apple)\b' --include='*.swift' "$HERE" >&2; then
  echo "testflight.sh: reword the App Intent descriptions above (Apple refuses these words in them)" >&2; exit 65
fi

if [ "$mode" != upload ]; then
  build=$(date -u +%Y%m%d%H%M)
  archive="$OUT/SamRabbit-$build.xcarchive"
  "$HERE/generate.sh" >/dev/null
  echo "archiving build $build"
  xcodebuild archive -project "$HERE/SamRabbit.xcodeproj" -scheme SamRabbit -configuration Release \
    -destination generic/platform=iOS -archivePath "$archive" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    CURRENT_PROJECT_VERSION="$build" >"$OUT/archive-$build.log" 2>&1 \
    || { tail -30 "$OUT/archive-$build.log" >&2; echo "archive failed (log: $OUT/archive-$build.log)" >&2; exit 1; }
  echo "$archive"
fi
[ "$mode" = archive ] && exit 0

cat >"$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  ${TEAM:+<key>teamID</key><string>$TEAM</string>}
  <key>uploadSymbols</key><true/>
  <key>testFlightInternalTestingOnly</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
echo "uploading $(basename "$archive")"
log="$OUT/upload-$(date -u +%Y%m%d%H%M%S).log"
if xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$OUT/export.plist" \
    -exportPath "$OUT/export" -allowProvisioningUpdates >"$log" 2>&1; then
  echo "uploaded. App Store Connect processes it in about 5-15 minutes, then TestFlight offers it."
else
  grep -iE 'error|not found|failed' "$log" | sort -u | head -12 >&2
  echo "upload failed (log: $log)" >&2
  exit 1
fi
