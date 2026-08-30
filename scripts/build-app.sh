#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-routingflare}"
PRODUCT_NAME="${PRODUCT_NAME:-TunnelBar}"
CLI_PRODUCT_NAME="${CLI_PRODUCT_NAME:-routingflare}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-TunnelBar}"
DISPLAY_NAME="${DISPLAY_NAME:-routingflare}"
BUNDLE_ID="${BUNDLE_ID:-com.gyuminhwangbo.RoutingFlare}"
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

"$ROOT_DIR/scripts/build-proxy.sh"
swift build -c "$CONFIGURATION" --product "$PRODUCT_NAME" --scratch-path "$ROOT_DIR/.build"
swift build -c "$CONFIGURATION" --product "$CLI_PRODUCT_NAME" --scratch-path "$ROOT_DIR/.build"

cp "$BUILD_DIR/$PRODUCT_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod 755 "$MACOS_DIR/$EXECUTABLE_NAME"
cp "$BUILD_DIR/$CLI_PRODUCT_NAME" "$MACOS_DIR/$CLI_PRODUCT_NAME"
chmod 755 "$MACOS_DIR/$CLI_PRODUCT_NAME"
cp "$ROOT_DIR/.build/proxy/routingflare-proxy" "$MACOS_DIR/routingflare-proxy"
chmod 755 "$MACOS_DIR/routingflare-proxy"

sed \
  -e "s/APP_BUNDLE_ID/$BUNDLE_ID/g" \
  -e "s/APP_EXECUTABLE_NAME/$EXECUTABLE_NAME/g" \
  -e "s/APP_DISPLAY_NAME/$DISPLAY_NAME/g" \
  -e "s/APP_VERSION/$VERSION/g" \
  -e "s/APP_BUILD/$BUILD_NUMBER/g" \
  "$ROOT_DIR/Resources/Info.plist" > "$CONTENTS_DIR/Info.plist"

cp "$ROOT_DIR/Resources/TunnelBar.entitlements" "$RESOURCES_DIR/TunnelBar.entitlements"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ROOT_DIR/Resources/KoFiButton.png" "$RESOURCES_DIR/KoFiButton.png"
cp "$ROOT_DIR/Resources/ThirdPartyNotices.txt" "$RESOURCES_DIR/ThirdPartyNotices.txt"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$MACOS_DIR/routingflare-proxy"
  codesign \
    --force \
    --timestamp \
    --options runtime \
    --sign "$CODESIGN_IDENTITY" \
    "$MACOS_DIR/$CLI_PRODUCT_NAME"

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
