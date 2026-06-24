#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-routingflare}"
VERSION="${VERSION:-1.0.0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="${DMG_PATH:-$ROOT_DIR/dist/$APP_NAME-$VERSION.dmg}"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Missing DMG at $DMG_PATH. Run scripts/package-dmg.sh first." >&2
  exit 1
fi

if [[ -z "${NOTARY_KEY_ID:-}" || -z "${NOTARY_ISSUER_ID:-}" || -z "${NOTARY_KEY_PATH:-}" ]]; then
  echo "Set NOTARY_KEY_ID, NOTARY_ISSUER_ID, and NOTARY_KEY_PATH for xcrun notarytool." >&2
  exit 1
fi

xcrun notarytool submit "$DMG_PATH" \
  --key "$NOTARY_KEY_PATH" \
  --key-id "$NOTARY_KEY_ID" \
  --issuer "$NOTARY_ISSUER_ID" \
  --wait

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"

echo "$DMG_PATH"
