#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodexBoard"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
BUILD_SCRIPT="$ROOT_DIR/script/build_and_run.sh"
SOURCE_ARCHIVE="$ROOT_DIR/dist/$APP_NAME-macOS.zip"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
RELEASE_TAG="v$VERSION"
RELEASE_NOTES="$ROOT_DIR/docs/releases/$RELEASE_TAG.md"
RELEASE_DIR="$ROOT_DIR/dist/release/$RELEASE_TAG"
RELEASE_ARCHIVE="$RELEASE_DIR/$APP_NAME-$RELEASE_TAG-macOS.zip"
CHECKSUM_FILE="$RELEASE_DIR/$APP_NAME-$RELEASE_TAG-SHA256SUMS.txt"
MANIFEST_FILE="$RELEASE_DIR/$APP_NAME-$RELEASE_TAG-release-manifest.txt"
COPIED_NOTES="$RELEASE_DIR/$APP_NAME-$RELEASE_TAG-release-notes.md"
VERIFY_DIR=""

cleanup() {
  if [[ -n "$VERIFY_DIR" && "$VERIFY_DIR" == /private/tmp/codexboard-release.* ]]; then
    rm -rf -- "$VERIFY_DIR"
  fi
}
trap cleanup EXIT

fail() {
  echo "Release packaging failed: $*" >&2
  exit 1
}

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] \
  || fail "invalid semantic version in Info.plist: $VERSION"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
  || fail "CFBundleVersion must be a positive integer"
[[ -s "$RELEASE_NOTES" ]] \
  || fail "missing release notes: $RELEASE_NOTES"
[[ -s "$ROOT_DIR/LICENSE" && -s "$ROOT_DIR/NOTICE" && -s "$ROOT_DIR/TRADEMARKS.md" ]] \
  || fail "missing project license, notice, or trademark guidelines"
grep -Fq "## [$VERSION]" "$ROOT_DIR/CHANGELOG.md" \
  || fail "CHANGELOG.md has no $VERSION section"

cd "$ROOT_DIR"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" swift test
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" "$BUILD_SCRIPT" --build
[[ -s "$SOURCE_ARCHIVE" ]] || fail "build did not produce $SOURCE_ARCHIVE"

VERIFY_DIR="$(mktemp -d /private/tmp/codexboard-release.XXXXXX)"
ditto -x -k "$SOURCE_ARCHIVE" "$VERIFY_DIR"
APP_BUNDLE="$VERIFY_DIR/$APP_NAME.app"
[[ -d "$APP_BUNDLE" ]] || fail "archive does not contain $APP_NAME.app"

ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
ACTUAL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
[[ "$ACTUAL_VERSION" == "$VERSION" ]] || fail "archive version mismatch"
[[ "$ACTUAL_BUILD" == "$BUILD_NUMBER" ]] || fail "archive build mismatch"
[[ "$ACTUAL_BUNDLE_ID" == "$BUNDLE_ID" ]] || fail "archive bundle identifier mismatch"

test -s "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
test -s "$APP_BUNDLE/Contents/Resources/Assets.car"
test -s "$APP_BUNDLE/Contents/Resources/en.lproj/Localizable.strings"
test -s "$APP_BUNDLE/Contents/Resources/zh-Hans.lproj/Localizable.strings"
test -s "$APP_BUNDLE/Contents/Resources/Legal/LICENSE"
test -s "$APP_BUNDLE/Contents/Resources/Legal/NOTICE"
test -s "$APP_BUNDLE/Contents/Resources/Legal/TRADEMARKS.md"
codesign --verify --strict --verbose=2 "$APP_BUNDLE"

SIGNING_DETAILS="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"
SIGNATURE_MODE="developer-id"
if grep -q 'Signature=adhoc' <<< "$SIGNING_DETAILS"; then
  SIGNATURE_MODE="ad-hoc"
fi

EXECUTABLE_ARCHITECTURES="$(lipo -archs "$APP_BUNDLE/Contents/MacOS/$APP_NAME")"

mkdir -p "$RELEASE_DIR"
cp "$SOURCE_ARCHIVE" "$RELEASE_ARCHIVE"
cp "$RELEASE_NOTES" "$COPIED_NOTES"

ARCHIVE_SHA256="$(shasum -a 256 "$RELEASE_ARCHIVE" | awk '{print $1}')"
ARCHIVE_BYTES="$(stat -f '%z' "$RELEASE_ARCHIVE")"
printf '%s  %s\n' "$ARCHIVE_SHA256" "$(basename "$RELEASE_ARCHIVE")" > "$CHECKSUM_FILE"

{
  echo "product=$APP_NAME"
  echo "license=Apache-2.0"
  echo "version=$VERSION"
  echo "build=$BUILD_NUMBER"
  echo "bundle_identifier=$BUNDLE_ID"
  echo "minimum_macos=$MINIMUM_SYSTEM_VERSION"
  echo "architectures=$EXECUTABLE_ARCHITECTURES"
  echo "signature=$SIGNATURE_MODE"
  echo "notarized=no"
  echo "archive=$(basename "$RELEASE_ARCHIVE")"
  echo "archive_bytes=$ARCHIVE_BYTES"
  echo "archive_sha256=$ARCHIVE_SHA256"
} > "$MANIFEST_FILE"

(
  cd "$RELEASE_DIR"
  shasum -a 256 -c "$(basename "$CHECKSUM_FILE")"
)

echo "Release kit created at: $RELEASE_DIR"
echo "Signature: $SIGNATURE_MODE (not notarized)"
