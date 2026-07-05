#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-ghkdqhrbals/routingflare}"
APP_NAME="${APP_NAME:-routingflare}"
DEST_DIR="${DEST_DIR:-/Applications}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
OPEN_AFTER_INSTALL="${OPEN_AFTER_INSTALL:-0}"
ASSET_TYPE="${ASSET_TYPE:-auto}"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    --open)
      OPEN_AFTER_INSTALL=1
      ;;
    --zip)
      ASSET_TYPE="zip"
      ;;
    --dmg)
      ASSET_TYPE="dmg"
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: scripts/install.sh [--dry-run] [--open] [--zip|--dmg]" >&2
      exit 1
      ;;
  esac
done

API_URL="https://api.github.com/repos/$REPO/releases/latest"
DEST_APP="$DEST_DIR/$APP_NAME.app"
CLI_SOURCE="$DEST_APP/Contents/MacOS/routingflare"
CLI_LINK="$BIN_DIR/routingflare"
TMP_DIR="$(mktemp -d /tmp/routingflare-install.XXXXXX)"
MOUNT_DIR="$TMP_DIR/mount"

cleanup() {
  if [[ -d "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

extract_json_string() {
  local key="$1"
  local file="$2"
  sed -nE 's/^[[:space:]]*"'"$key"'":[[:space:]]*"([^"]+)".*$/\1/p' "$file" | head -n 1
}

ensure_path_line() {
  local zshrc="$HOME/.zshrc"
  local path_line='export PATH="$HOME/.local/bin:$PATH"'
  if [[ -f "$zshrc" ]] && grep -Fq ".local/bin" "$zshrc"; then
    return
  fi
  mkdir -p "$(dirname "$zshrc")"
  {
    [[ ! -f "$zshrc" || -s "$zshrc" ]] && echo
    echo "$path_line"
  } >> "$zshrc"
}

install_app() {
  local source_app="$1"
  if [[ -w "$DEST_DIR" ]]; then
    rm -rf "$DEST_APP"
    ditto "$source_app" "$DEST_APP"
    xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
  else
    sudo rm -rf "$DEST_APP"
    sudo ditto "$source_app" "$DEST_APP"
    sudo xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
  fi
}

require_command curl
require_command ditto
require_command sed

installed_version() {
  local info_plist="$DEST_APP/Contents/Info.plist"
  if [[ ! -f "$info_plist" ]]; then
    return
  fi
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info_plist" 2>/dev/null || true
}

RELEASE_JSON="$TMP_DIR/release.json"
echo "Fetching latest routingflare release..."
curl -fsSL "$API_URL" -o "$RELEASE_JSON"

VERSION="$(extract_json_string "tag_name" "$RELEASE_JSON")"
VERSION="${VERSION#v}"
VERSION="${VERSION#V}"
ZIP_URL="$(sed -nE 's/^[[:space:]]*"browser_download_url":[[:space:]]*"([^"]+\.zip)".*$/\1/p' "$RELEASE_JSON" | head -n 1)"
DMG_URL="$(sed -nE 's/^[[:space:]]*"browser_download_url":[[:space:]]*"([^"]+\.dmg)".*$/\1/p' "$RELEASE_JSON" | head -n 1)"

if [[ -z "$VERSION" ]]; then
  echo "Could not read the latest release version." >&2
  exit 1
fi

echo "Latest version: $VERSION"

CURRENT_VERSION="$(installed_version)"
if [[ -n "$CURRENT_VERSION" && "$CURRENT_VERSION" == "$VERSION" ]]; then
  echo "routingflare $CURRENT_VERSION is already installed."
  echo "Ensuring CLI is installed at $CLI_LINK..."
  mkdir -p "$BIN_DIR"
  if [[ -x "$CLI_SOURCE" ]]; then
    ln -sf "$CLI_SOURCE" "$CLI_LINK"
    ensure_path_line
    echo "CLI: $CLI_LINK"
    echo 'Open a new terminal or run: source ~/.zshrc'
  else
    echo "CLI source was not found at $CLI_SOURCE" >&2
  fi
  exit 0
fi

case "$ASSET_TYPE" in
  zip)
    ASSET_URL="$ZIP_URL"
    ASSET_EXT="zip"
    ;;
  dmg)
    ASSET_URL="$DMG_URL"
    ASSET_EXT="dmg"
    ;;
  auto)
    if [[ -n "$ZIP_URL" ]]; then
      ASSET_URL="$ZIP_URL"
      ASSET_EXT="zip"
    else
      ASSET_URL="$DMG_URL"
      ASSET_EXT="dmg"
    fi
    ;;
  *)
    echo "Invalid ASSET_TYPE: $ASSET_TYPE" >&2
    exit 1
    ;;
esac

if [[ -z "${ASSET_URL:-}" ]]; then
  echo "Could not find a $ASSET_EXT asset in the latest release." >&2
  exit 1
fi

echo "Asset: $ASSET_URL"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run complete. No files were installed."
  exit 0
fi

ASSET_PATH="$TMP_DIR/$APP_NAME-$VERSION.$ASSET_EXT"

echo "Downloading $ASSET_EXT..."
curl -fL "$ASSET_URL" -o "$ASSET_PATH"

if [[ "$ASSET_EXT" == "zip" ]]; then
  require_command unzip
  EXTRACT_DIR="$TMP_DIR/extract"
  mkdir -p "$EXTRACT_DIR"
  echo "Extracting ZIP..."
  unzip -q "$ASSET_PATH" -d "$EXTRACT_DIR"
  SOURCE_APP="$(find "$EXTRACT_DIR" -maxdepth 2 -name '*.app' -type d | head -n 1)"
else
  require_command hdiutil
  mkdir -p "$MOUNT_DIR"
  echo "Mounting DMG..."
  hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$ASSET_PATH" >/dev/null
  SOURCE_APP="$MOUNT_DIR/$APP_NAME.app"
  if [[ ! -d "$SOURCE_APP" ]]; then
    SOURCE_APP="$(find "$MOUNT_DIR" -maxdepth 1 -name '*.app' -type d | head -n 1)"
  fi
fi

if [[ -z "$SOURCE_APP" || ! -d "$SOURCE_APP" ]]; then
  echo "No app bundle found in $ASSET_EXT." >&2
  exit 1
fi

echo "Closing running routingflare app if needed..."
osascript -e 'tell application id "com.gyuminhwangbo.RoutingFlare" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application id "dev.local.tunnelbar" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application id "dev.local.routingflare" to quit' >/dev/null 2>&1 || true
sleep 1

echo "Installing to $DEST_APP..."
install_app "$SOURCE_APP"

echo "Installing CLI to $CLI_LINK..."
mkdir -p "$BIN_DIR"
ln -sf "$CLI_SOURCE" "$CLI_LINK"
ensure_path_line

if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
  open "$DEST_APP"
fi

echo "routingflare $VERSION installed."
echo "CLI: $CLI_LINK"
echo 'Open a new terminal or run: source ~/.zshrc'
