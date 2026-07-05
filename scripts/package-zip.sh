#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-routingflare}"
VERSION="${VERSION:-1.0.0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"

if [[ ! -d "$APP_DIR" ]]; then
  echo "Missing $APP_DIR. Run scripts/build-app.sh first." >&2
  exit 1
fi

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

echo "$ZIP_PATH"
