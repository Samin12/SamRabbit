#!/usr/bin/env bash
# Compiles apple/Shared/SamRabbitKit into a Swift 6 static library for the desktop app (build.sh) and the voice
# tests (tests/voice/headless.sh): <dir>/libSamRabbitKit.a and <dir>/SamRabbitKit.swiftmodule. Cached: does nothing
# while the library is newer than every SamRabbitKit source and was built for the same target, by the same compiler
# (a module from another Swift can't be imported) and from the same files (a deleted source rebuilds too).
#
#   companion/desktop/tools/build_samrabbitkit.sh <dir> <target>      e.g. ... build/SamRabbitKit arm64-apple-macos26.0
set -euo pipefail

KIT=$1
TARGET=$2
HERE=$(cd "$(dirname "$0")" && pwd)
SOURCES="$HERE/../../../apple/Shared/SamRabbitKit/Sources/SamRabbitKit"
LIB="$KIT/libSamRabbitKit.a"
FILES=()
while IFS= read -r file; do FILES+=("$file"); done < <(find "$SOURCES" -name '*.swift' | LC_ALL=C sort)
STAMP=$(printf '%s\n' "$TARGET" "$(xcrun swiftc --version 2>/dev/null | head -1)" "${FILES[@]#"$SOURCES"/}")
if [ -s "$LIB" ] && [ "$(cat "$KIT/stamp" 2>/dev/null)" = "$STAMP" ] &&
   [ -z "$(find "$SOURCES" -name '*.swift' -newer "$LIB" | head -1)" ]; then
  exit 0
fi
echo "compiling SamRabbitKit"
rm -rf "$KIT"
mkdir -p "$KIT"
xcrun swiftc -O -whole-module-optimization -swift-version 6 -parse-as-library -target "$TARGET" \
  -module-name SamRabbitKit -emit-module -emit-module-path "$KIT/SamRabbitKit.swiftmodule" \
  -emit-library -static -o "$LIB" "${FILES[@]}"
printf '%s\n' "$STAMP" > "$KIT/stamp"
