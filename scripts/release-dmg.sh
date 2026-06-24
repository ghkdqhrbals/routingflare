#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$ROOT_DIR/scripts/build-app.sh"
"$ROOT_DIR/scripts/package-dmg.sh"
"$ROOT_DIR/scripts/notarize-dmg.sh"
