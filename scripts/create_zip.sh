#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="${MIMI_APP_NAME:-mimi}"
APP_DIR="$ROOT_DIR/build/$APP_NAME.app"
ZIP_PATH="${1:-$ROOT_DIR/build/$APP_NAME.zip}"

if [[ ! -d "$APP_DIR" ]]; then
  echo "error: missing $APP_DIR; run scripts/build_app.sh first" >&2
  exit 1
fi

mkdir -p "$(dirname "$ZIP_PATH")"
rm -f "$ZIP_PATH"

# ditto preserves app bundle metadata/resource forks better than plain zip.
ditto -c -k --keepParent --sequesterRsrc --rsrc "$APP_DIR" "$ZIP_PATH"

echo "Built $ZIP_PATH"
