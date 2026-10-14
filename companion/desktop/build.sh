#!/usr/bin/env bash
# Builds SamRabbit.app (native shell + web UI) into companion/desktop/build/SamRabbit.app.
#
#   companion/desktop/build.sh [--out <dir>] [--bundle-id <id>] [--adhoc]
#
# Needs Xcode's command line tools (xcrun swiftc, iconutil, codesign). No package managers, no
# network. The voice (Sources/Voice*.swift) uses apple/Shared/SamRabbitKit, compiled here as a
# Swift 6 static library (cached until its sources change). Signed with the keychain's "Apple
# Development" identity when there is one, so macOS keeps the microphone grant across rebuilds;
# else ad-hoc (codesign -s -). --adhoc always signs ad-hoc. Bundle id com.samrabbit.desktop
# (--bundle-id for a development copy that never replaces the installed app's settings or grants).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/build"
BUNDLE_ID=com.samrabbit.desktop
ADHOC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=$2; shift 2 ;;
    --bundle-id) BUNDLE_ID=$2; shift 2 ;;
    --adhoc) ADHOC=1; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "build.sh: unknown option $1" >&2; exit 64 ;;
  esac
done

APP="$OUT/SamRabbit.app"
VERSION=1.0.0
BUILD=$(git -C "$HERE" rev-list --count HEAD 2>/dev/null || date +%Y%m%d)
# macOS 26: the on-device speech recognizer for "Hey Rabbit" (SpeechAnalyzer) and SamRabbitKit.
MIN_OS=26.0
TARGET=arm64-apple-macos$MIN_OS
[ "$(uname -m)" = x86_64 ] && TARGET=x86_64-apple-macos$MIN_OS
mkdir -p "$OUT"

# 1. App icon: render the orb (CoreGraphics) and pack an .icns (cached until the sources change).
ICNS="$OUT/AppIcon.icns"
if [ ! -s "$ICNS" ] || [ "$HERE/tools/render_icon.swift" -nt "$ICNS" ] || [ "$HERE/Sources/OrbRenderer.swift" -nt "$ICNS" ]; then
  echo "rendering the app icon"
  xcrun swiftc -O -swift-version 5 -parse-as-library -target "$TARGET" \
    "$HERE/tools/render_icon.swift" "$HERE/Sources/OrbRenderer.swift" -o "$OUT/render_icon"
  "$OUT/render_icon" "$OUT/AppIcon-1024.png"
  ICONSET="$OUT/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$OUT/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$OUT/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICNS"
  rm -rf "$ICONSET"
fi

# 2. SamRabbitKit (the watch's conversation rules, speech detector, streaming turns and jitter buffer) as a
#    Swift 6 static library, rebuilt only when one of its sources changed.
KIT="$OUT/SamRabbitKit"
"$HERE/tools/build_samrabbitkit.sh" "$KIT" "$TARGET"

# 3. The native shell.
echo "compiling SamRabbit"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -parse-as-library -target "$TARGET" \
  -I "$KIT" -L "$KIT" -lSamRabbitKit \
  "$HERE"/Sources/*.swift -o "$APP/Contents/MacOS/SamRabbit" \
  -framework SwiftUI -framework WebKit -framework AppKit -framework UserNotifications -framework CoreImage \
  -framework AVFoundation -framework CoreMedia -framework Speech -framework Carbon

# 4. Bundle: Info.plist, icon, web UI.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SamRabbit</string>
  <key>CFBundleDisplayName</key><string>SamRabbit</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>SamRabbit</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSUIElement</key><false/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>SamRabbit companion for the Rabbit R1</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSMicrophoneUsageDescription</key><string>SamRabbit listens when you talk to it: the mic button, Control-Option-Space, or “Hey Rabbit”. The wake phrase is recognized on this Mac, and nothing is sent anywhere before it.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>SamRabbit recognizes “Hey Rabbit” on this Mac, on device only.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/web"
# Only the files the bridge will serve (no dotfiles, no dev files).
( cd "$HERE/web" && find . -type f ! -name '.*' \( -name '*.html' -o -name '*.css' -o -name '*.js' -o -name '*.svg' -o -name '*.png' \) ) |
  while read -r file; do
    mkdir -p "$APP/Contents/Resources/web/$(dirname "$file")"
    install -m 0644 "$HERE/web/$file" "$APP/Contents/Resources/web/$file"
  done

# 5. Signature: the "Apple Development" identity when the keychain has one (a stable identity, so macOS
#    remembers the microphone grant across rebuilds), else ad-hoc. No hardened runtime (nothing to notarize).
IDENTITY=-
SIGNED_WITH=ad-hoc
if [ "$ADHOC" != 1 ]; then
  CERT=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: / { print $2; exit }')
  if [ -n "$CERT" ]; then IDENTITY=$CERT; SIGNED_WITH="Apple Development"; fi
fi
codesign -s "$IDENTITY" --force --deep --timestamp=none "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP"
echo "built $APP ($(du -sh "$APP" | cut -f1), signed $SIGNED_WITH)"
