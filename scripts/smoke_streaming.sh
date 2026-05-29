#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIO_DIR="${TMPDIR:-/tmp}/mimi-smoke"
AIFF_PATH="$AUDIO_DIR/streaming.aiff"
WAV_PATH="$AUDIO_DIR/streaming.wav"

mkdir -p "$AUDIO_DIR"

say -o "$AIFF_PATH" "mimi streaming smoke test please press enter after paste"
afconvert "$AIFF_PATH" -f WAVE -d LEF32@16000 "$WAV_PATH"

cd "$ROOT_DIR"
swift run SokkiSmoke apple-stream-file "$WAV_PATH"
