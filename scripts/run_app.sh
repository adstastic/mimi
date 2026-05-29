#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${MIMI_APP_NAME:-mimi}"

"$ROOT_DIR/scripts/build_app.sh"
open "$ROOT_DIR/build/$APP_NAME.app"
