#!/bin/bash
# Run on an Apple Silicon Mac with Flutter and Xcode. No paid certificate needed.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'This package must be built on an Apple Silicon macOS runner.' >&2
  exit 1
fi
for command in flutter xcrun codesign ditto hdiutil python3; do
  command -v "$command" >/dev/null
done
VERSION="$(python3 - <<'PY'
from pathlib import Path
import json, re
version = re.search(r'^version:\s*(\S+)', Path('pubspec.yaml').read_text(), re.M).group(1)
release = json.loads(Path('assets/release-info.json').read_text())
assert version == f'{release["version"]}+{release["build"]}', 'Release version mismatch'
assert re.fullmatch(r'\d+\.\d+\.\d+\+\d+', version), 'Invalid release version'
print(version)
PY
)"
NAME="Idreaml-Clip-${VERSION}-macos-arm64"
OUTPUT="$PWD/dist/macos"
mkdir -p "$OUTPUT" "$PWD/build"
if [[ -e "$OUTPUT/$NAME.dmg" || -e "$OUTPUT/$NAME.zip" ]]; then
  echo "Refusing to overwrite an existing release: $NAME" >&2
  exit 1
fi
STAGING="$(mktemp -d "$PWD/build/macos-package.XXXXXX")"
APP="$STAGING/Idreaml Clip.app"
# The project retains App Sandbox and its existing entitlements. Xcode's '-'
# identity creates a local signature without contacting Apple or using a team.
flutter build macos --release --no-pub
SOURCE_APP="build/macos/Build/Products/Release/idreaml_clip.app"
test -d "$SOURCE_APP"
ditto "$SOURCE_APP" "$APP"
export PACKAGE_APP="$APP" PACKAGE_OUTPUT="$OUTPUT" PACKAGE_NAME="$NAME"
python3 scripts/verify-macos-bundle.py

# Sign nested code from the inside out after thinning any universal libraries.
while IFS= read -r -d '' binary; do
  if file -b "$binary" | grep -q 'Mach-O'; then
    codesign --force --sign - --timestamp=none "$binary"
  fi
done < <(find "$APP/Contents" -type f -print0)
while IFS= read -r framework; do
  codesign --force --sign - --timestamp=none "$framework"
done < <(find "$APP/Contents" -depth -type d -name '*.framework')
codesign --force --sign - --timestamp=none \
  --entitlements macos/Runner/Release.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# Launch in the disposable build account to catch loader/startup crashes.
# A surviving process is a smoke check, not a substitute for interactive tests.
"$APP/Contents/MacOS/idreaml_clip" > "$OUTPUT/startup.log" 2>&1 &
APP_PID=$!
trap 'kill "$APP_PID" 2>/dev/null || true' EXIT
sleep 12
if ! kill -0 "$APP_PID" 2>/dev/null; then
  cat "$OUTPUT/startup.log"
  echo 'The packaged app exited during its startup smoke check.' >&2
  exit 1
fi
kill "$APP_PID"
wait "$APP_PID" || true
trap - EXIT

cp scripts/macos-package-readme.txt "$STAGING/安装说明.txt"
python3 scripts/build-user-guide.py
GUIDE="doc/Idreaml-Clip-${VERSION%+*}-使用指南.html"
cp "$GUIDE" "$STAGING/使用指南.html"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/$NAME.zip"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Idreaml Clip ${VERSION%+*}" -srcfolder "$STAGING" \
  -format UDZO -ov "$OUTPUT/$NAME.dmg"
hdiutil verify "$OUTPUT/$NAME.dmg"
cp scripts/macos-package-readme.txt "$OUTPUT/安装说明.txt"
cp "$GUIDE" "$OUTPUT/使用指南.html"
(
  cd "$OUTPUT"
  shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt
)
echo "Created $OUTPUT/$NAME.dmg and $OUTPUT/$NAME.zip"
