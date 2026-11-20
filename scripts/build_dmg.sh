#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
DERIVED_DIR="$PROJECT_DIR/.build/DerivedData"
APP_DIR="$DIST_DIR/Orfeus.app"
DMG_PATH="$DIST_DIR/Orfeus.dmg"

cd "$PROJECT_DIR"

echo "1) Running AudioCore and MixerModel unit tests..."
swift test --package-path Packages/AudioCore
swift test --package-path Packages/MixerModel

echo "2) Building and testing Orfeus Xcode scheme..."
xcodebuild \
  -project "$PROJECT_DIR/Orfeus.xcodeproj" \
  -scheme "Orfeus" \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$DERIVED_DIR" \
  clean test

echo "3) Building Release Orfeus.app..."
xcodebuild \
  -project "$PROJECT_DIR/Orfeus.xcodeproj" \
  -scheme "Orfeus" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

BUILT_APP="$DERIVED_DIR/Build/Products/Release/Orfeus.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "Error: Built Orfeus.app not found at $BUILT_APP" >&2
  exit 1
fi

echo "4) Assembling dist/Orfeus.app..."
rm -rf "$APP_DIR"
mkdir -p "$DIST_DIR"
ditto "$BUILT_APP" "$APP_DIR"

echo "5) Signing Orfeus.app with Hardened Runtime..."
codesign --force --options runtime --sign - "$APP_DIR"

echo "6) Verifying signature and Hardened Runtime..."
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
CODESIGN_DV="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1)"
case "$CODESIGN_DV" in
  *runtime*) ;;
  *)
    echo "Error: Hardened Runtime flag missing on Orfeus.app" >&2
    exit 1
    ;;
esac

echo "7) Creating dist/Orfeus.dmg..."
STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_DIR" "$STAGING_DIR/Orfeus.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create -volname "Orfeus" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

echo "8) Release artifacts:"
lipo -info "$APP_DIR/Contents/MacOS/Orfeus"
ls -lh "$DMG_PATH"
shasum -a 256 "$DMG_PATH"
