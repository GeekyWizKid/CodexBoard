#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexBoard"
BUNDLE_ID="com.local.CodexBoard"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
ARCHIVE_PATH="$DIST_DIR/$APP_NAME-macOS.zip"
LEGACY_APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
RUNTIME_DIR="/private/tmp/codexboard-runtime-$(id -u)"
RUNTIME_APP="$RUNTIME_DIR/$APP_NAME.app"
RUNTIME_BINARY="$RUNTIME_APP/Contents/MacOS/$APP_NAME"
INFO_PLIST_SOURCE="$ROOT_DIR/Resources/Info.plist"
FILE_ICONS_SOURCE="$ROOT_DIR/Resources/FileIcons"
APP_ICON_SOURCE="$ROOT_DIR/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"
ASSET_CATALOG_SOURCE="$ROOT_DIR/Resources/Assets.xcassets"
LOCALIZATION_SOURCE="$ROOT_DIR/Resources"
PROJECT_LICENSE="$ROOT_DIR/LICENSE"
PROJECT_NOTICE="$ROOT_DIR/NOTICE"
TRADEMARK_GUIDELINES="$ROOT_DIR/TRADEMARKS.md"
DEVELOPER_ROOT="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ ! -x "$DEVELOPER_ROOT/usr/bin/actool" && -x "/Applications/Xcode.app/Contents/Developer/usr/bin/actool" ]]; then
  DEVELOPER_ROOT="/Applications/Xcode.app/Contents/Developer"
fi
ACTOOL="$DEVELOPER_ROOT/usr/bin/actool"
STAGING_DIR=""

cleanup_staging() {
  if [[ -n "$STAGING_DIR" && "$STAGING_DIR" == /private/tmp/codexboard-stage.* ]]; then
    rm -rf -- "$STAGING_DIR"
  fi
}
trap cleanup_staging EXIT

stop_exact_binary() {
  local binary_path="$1"
  local pids=""
  pids="$(pgrep -f "^${binary_path}$" 2>/dev/null || true)"
  [[ -z "$pids" ]] && return 0

  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
  done <<< "$pids"

  for _ in {1..30}; do
    pgrep -f "^${binary_path}$" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  echo "Unable to stop the existing $APP_NAME process at $binary_path" >&2
  return 1
}

build_bundle() {
  cd "$ROOT_DIR"
  local required_icon
  for required_icon in \
    default_file.svg \
    file_type_swift.svg \
    file_type_typescript_official.svg \
    file_type_python.svg \
    file_type_docker2.svg \
    LICENSE-vscode-icons.txt; do
    if [[ ! -s "$FILE_ICONS_SOURCE/$required_icon" ]]; then
      echo "Missing required file icon resource: $FILE_ICONS_SOURCE/$required_icon" >&2
      return 1
    fi
  done
  if [[ ! -s "$APP_ICON_SOURCE" ]]; then
    echo "Missing application icon: $APP_ICON_SOURCE" >&2
    return 1
  fi
  if [[ ! -x "$ACTOOL" ]]; then
    echo "Unable to find actool. Install or select a full Xcode toolchain." >&2
    return 1
  fi
  local localization
  for localization in en zh-Hans; do
    if [[ ! -s "$LOCALIZATION_SOURCE/$localization.lproj/Localizable.strings" ]]; then
      echo "Missing localization: $localization" >&2
      return 1
    fi
  done
  for legal_file in "$PROJECT_LICENSE" "$PROJECT_NOTICE" "$TRADEMARK_GUIDELINES"; do
    if [[ ! -s "$legal_file" ]]; then
      echo "Missing legal document: $legal_file" >&2
      return 1
    fi
  done

  swift build -c release
  local build_binary
  local staged_bundle
  local staged_archive
  local verification_dir
  local asset_info_plist
  build_binary="$(swift build -c release --show-bin-path)/$APP_NAME"
  STAGING_DIR="$(mktemp -d "/private/tmp/codexboard-stage.XXXXXX")"
  staged_bundle="$STAGING_DIR/$APP_NAME.app"
  staged_archive="$STAGING_DIR/$APP_NAME-macOS.zip"
  verification_dir="$STAGING_DIR/verify"
  asset_info_plist="$STAGING_DIR/asset-info.plist"

  mkdir -p "$staged_bundle/Contents/MacOS" "$staged_bundle/Contents/Resources"
  cp "$build_binary" "$staged_bundle/Contents/MacOS/$APP_NAME"
  cp "$INFO_PLIST_SOURCE" "$staged_bundle/Contents/Info.plist"
  cp -R "$FILE_ICONS_SOURCE" "$staged_bundle/Contents/Resources/FileIcons"
  cp -R "$LOCALIZATION_SOURCE/en.lproj" "$staged_bundle/Contents/Resources/en.lproj"
  cp -R "$LOCALIZATION_SOURCE/zh-Hans.lproj" "$staged_bundle/Contents/Resources/zh-Hans.lproj"
  mkdir -p "$staged_bundle/Contents/Resources/Legal"
  cp "$PROJECT_LICENSE" "$staged_bundle/Contents/Resources/Legal/LICENSE"
  cp "$PROJECT_NOTICE" "$staged_bundle/Contents/Resources/Legal/NOTICE"
  cp "$TRADEMARK_GUIDELINES" "$staged_bundle/Contents/Resources/Legal/TRADEMARKS.md"
  "$ACTOOL" "$ASSET_CATALOG_SOURCE" \
    --compile "$staged_bundle/Contents/Resources" \
    --output-format human-readable-text \
    --notices \
    --warnings \
    --app-icon AppIcon \
    --include-all-app-icons \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --target-device mac \
    --output-partial-info-plist "$asset_info_plist"
  chmod 0755 "$staged_bundle/Contents/MacOS/$APP_NAME"
  xattr -cr "$staged_bundle"
  codesign --force --sign - --timestamp=none "$staged_bundle"
  codesign --verify --strict --verbose=2 "$staged_bundle"
  ditto -c -k --keepParent "$staged_bundle" "$staged_archive"

  mkdir -p "$DIST_DIR"
  rm -f -- "$ARCHIVE_PATH"
  cp "$staged_archive" "$ARCHIVE_PATH"
  chmod 0644 "$ARCHIVE_PATH"

  mkdir -p "$verification_dir"
  ditto -x -k "$ARCHIVE_PATH" "$verification_dir"
  test -s "$verification_dir/$APP_NAME.app/Contents/Resources/FileIcons/default_file.svg"
  test -s "$verification_dir/$APP_NAME.app/Contents/Resources/FileIcons/LICENSE-vscode-icons.txt"
  test -s "$verification_dir/$APP_NAME.app/Contents/Resources/Assets.car"
  test -s "$verification_dir/$APP_NAME.app/Contents/Resources/AppIcon.icns"
  test -s "$verification_dir/$APP_NAME.app/Contents/Resources/en.lproj/Localizable.strings"
  test -s "$verification_dir/$APP_NAME.app/Contents/Resources/zh-Hans.lproj/Localizable.strings"
  test -s "$verification_dir/$APP_NAME.app/Contents/Resources/Legal/LICENSE"
  test -s "$verification_dir/$APP_NAME.app/Contents/Resources/Legal/NOTICE"
  test -s "$verification_dir/$APP_NAME.app/Contents/Resources/Legal/TRADEMARKS.md"
  codesign --verify --strict --verbose=2 "$verification_dir/$APP_NAME.app"

  # Older builds placed a raw app under Desktop. Remove only that known output;
  # the signed ZIP is stable even when Desktop is managed by File Provider.
  stop_exact_binary "$LEGACY_APP_BUNDLE/Contents/MacOS/$APP_NAME"
  rm -rf -- "$LEGACY_APP_BUNDLE"
}

prepare_runtime_bundle() {
  [[ "$RUNTIME_DIR" == "/private/tmp/codexboard-runtime-$(id -u)" ]] || {
    echo "Refusing unexpected runtime path: $RUNTIME_DIR" >&2
    exit 1
  }
  stop_exact_binary "$RUNTIME_BINARY"
  rm -rf -- "$RUNTIME_DIR"
  mkdir -p "$RUNTIME_DIR"
  ditto -x -k "$ARCHIVE_PATH" "$RUNTIME_DIR"
  xattr -cr "$RUNTIME_APP"
  codesign --verify --strict --verbose=2 "$RUNTIME_APP"
}

launch_bundle() {
  prepare_runtime_bundle
  /usr/bin/open -n "$RUNTIME_APP"
}

case "$MODE" in
  build|--build)
    build_bundle
    ;;
  run)
    build_bundle
    launch_bundle
    ;;
  --verify|verify)
    build_bundle
    launch_bundle
    for _ in {1..30}; do
      if pgrep -f "^${RUNTIME_BINARY}$" >/dev/null; then
        exit 0
      fi
      sleep 0.2
    done
    echo "$APP_NAME did not stay running" >&2
    exit 1
    ;;
  --debug|debug)
    cd "$ROOT_DIR"
    swift build
    DEBUG_BINARY="$(swift build --show-bin-path)/$APP_NAME"
    lldb -- "$DEBUG_BINARY"
    ;;
  --logs|logs)
    build_bundle
    launch_bundle
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    build_bundle
    launch_bundle
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  *)
    echo "usage: $0 [run|build|--verify|--debug|--logs|--telemetry]" >&2
    exit 2
    ;;
esac
