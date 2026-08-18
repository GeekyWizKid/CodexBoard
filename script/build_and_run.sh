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
DATA_PATH_ENV="CODEXBOARD_DATA_PATH"
VERIFY_DATA_PATH=""
INFO_PLIST_SOURCE="$ROOT_DIR/Resources/Info.plist"
STAGING_DIR=""
STOP_RUNTIME_ON_EXIT=false

cleanup_staging() {
  if [[ -n "$STAGING_DIR" && "$STAGING_DIR" == /private/tmp/codexboard-stage.* ]]; then
    rm -rf -- "$STAGING_DIR"
  fi
}

cleanup() {
  if [[ "$STOP_RUNTIME_ON_EXIT" == true ]]; then
    stop_exact_binary "$RUNTIME_BINARY" || true
  fi
  cleanup_staging
}
trap cleanup EXIT

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
  swift build -c release
  local build_binary
  local staged_bundle
  local staged_archive
  local verification_dir
  build_binary="$(swift build -c release --show-bin-path)/$APP_NAME"
  STAGING_DIR="$(mktemp -d "/private/tmp/codexboard-stage.XXXXXX")"
  staged_bundle="$STAGING_DIR/$APP_NAME.app"
  staged_archive="$STAGING_DIR/$APP_NAME-macOS.zip"
  verification_dir="$STAGING_DIR/verify"

  mkdir -p "$staged_bundle/Contents/MacOS"
  cp "$build_binary" "$staged_bundle/Contents/MacOS/$APP_NAME"
  cp "$INFO_PLIST_SOURCE" "$staged_bundle/Contents/Info.plist"
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
  local launch_mode="${1:-normal}"
  prepare_runtime_bundle
  case "$launch_mode" in
    normal)
      /usr/bin/env -u "$DATA_PATH_ENV" /usr/bin/open -n "$RUNTIME_APP"
      ;;
    isolated-verification)
      local verify_data_directory
      verify_data_directory="$(mktemp -d "$RUNTIME_DIR/verify-data.XXXXXX")"
      VERIFY_DATA_PATH="$verify_data_directory/board.json"
      /usr/bin/open -n --env "$DATA_PATH_ENV=$VERIFY_DATA_PATH" "$RUNTIME_APP"
      ;;
    *)
      echo "Unknown launch mode: $launch_mode" >&2
      return 2
      ;;
  esac
}

validate_verification_data() {
  local data_directory="${VERIFY_DATA_PATH%/*}"
  [[ -s "$VERIFY_DATA_PATH" ]] || return 1
  /usr/bin/plutil -convert binary1 -o /dev/null -- "$VERIFY_DATA_PATH" \
    >/dev/null 2>&1 || return 1
  [[ "$(/usr/bin/stat -f '%Lp' "$data_directory")" == 700 ]] || return 1
  [[ "$(/usr/bin/stat -f '%Lp' "$VERIFY_DATA_PATH")" == 600 ]] || return 1
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
    STOP_RUNTIME_ON_EXIT=true
    launch_bundle isolated-verification
    for _ in {1..150}; do
      if pgrep -f "^${RUNTIME_BINARY}$" >/dev/null && validate_verification_data; then
        echo "Verified $APP_NAME with isolated JSON at $VERIFY_DATA_PATH (directory 0700, file 0600)"
        exit 0
      fi
      sleep 0.2
    done
    if pgrep -f "^${RUNTIME_BINARY}$" >/dev/null; then
      if [[ ! -s "$VERIFY_DATA_PATH" ]]; then
        echo "$APP_NAME is running but did not create isolated verification data" >&2
      elif ! /usr/bin/plutil -convert binary1 -o /dev/null -- "$VERIFY_DATA_PATH" \
        >/dev/null 2>&1; then
        echo "$APP_NAME created invalid isolated JSON at $VERIFY_DATA_PATH" >&2
      else
        verify_data_directory="${VERIFY_DATA_PATH%/*}"
        echo "$APP_NAME created isolated data with unsafe permissions: directory $(/usr/bin/stat -f '%Lp' "$verify_data_directory"), file $(/usr/bin/stat -f '%Lp' "$VERIFY_DATA_PATH")" >&2
      fi
    else
      echo "$APP_NAME did not stay running" >&2
    fi
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
