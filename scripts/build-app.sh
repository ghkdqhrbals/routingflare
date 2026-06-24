#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-routingflare}"
PRODUCT_NAME="${PRODUCT_NAME:-TunnelBar}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-TunnelBar}"
DISPLAY_NAME="${DISPLAY_NAME:-routingflare}"
BUNDLE_ID="${BUNDLE_ID:-dev.local.tunnelbar}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CONFIGURATION="${CONFIGURATION:-release}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME" --scratch-path "$ROOT_DIR/.build"

cp "$BUILD_DIR/$PRODUCT_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME"

sed \
  -e "s/APP_BUNDLE_ID/$BUNDLE_ID/g" \
  -e "s/APP_EXECUTABLE_NAME/$EXECUTABLE_NAME/g" \
  -e "s/APP_DISPLAY_NAME/$DISPLAY_NAME/g" \
  -e "s/APP_VERSION/$VERSION/g" \
  -e "s/APP_BUILD/$BUILD_NUMBER/g" \
  "$ROOT_DIR/Resources/Info.plist" > "$CONTENTS_DIR/Info.plist"

cp "$ROOT_DIR/Resources/TunnelBar.entitlements" "$RESOURCES_DIR/TunnelBar.entitlements"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign \
    --force \
    --timestamp \
    --options runtime \
    --entitlements "$ROOT_DIR/Resources/TunnelBar.entitlements" \
    --sign "$CODESIGN_IDENTITY" \
    "$APP_DIR"

  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
fi

echo "$APP_DIR"
