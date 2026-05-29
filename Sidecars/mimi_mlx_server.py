#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["parakeet-mlx==0.5.1"]
# ///

import contextlib
import json
import os
import sys
import time
import traceback

MODEL_ID = os.environ.get("MIMI_PARAKEET_MODEL", "mlx-community/parakeet-tdt-0.6b-v2")
CACHE_DIR = os.environ.get("MIMI_MODEL_CACHE") or None
HOMEBREW_PATH = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
if HOMEBREW_PATH not in os.environ.get("PATH", ""):
    os.environ["PATH"] = HOMEBREW_PATH + ":" + os.environ.get("PATH", "")


def emit(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    emit({"event": "loading", "model": MODEL_ID})

    try:
        with contextlib.redirect_stdout(sys.stderr):
            import mlx.core as mx
            from parakeet_mlx import from_pretrained
            from parakeet_mlx.parakeet import DecodingConfig, Greedy, SentenceConfig

            model = from_pretrained(MODEL_ID, dtype=mx.bfloat16, cache_dir=CACHE_DIR)
            decoding_config = DecodingConfig(decoding=Greedy(), sentence=SentenceConfig())
    except Exception as exc:
        emit({"event": "error", "message": f"failed to load {MODEL_ID}: {exc}"})
        traceback.print_exc(file=sys.stderr)
        return 1

    emit({"event": "ready", "model": MODEL_ID})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        request_id = None
        try:
            request = json.loads(line)
            request_id = request.get("id")
            command = request.get("command")

            if command == "shutdown":
                emit({"event": "shutdown"})
                return 0

            if command != "transcribe":
                raise ValueError(f"unknown command: {command}")

            path = request.get("path")
            if not path:
                raise ValueError("missing audio path")

            started = time.perf_counter()
            with contextlib.redirect_stdout(sys.stderr):
                result = model.transcribe(
                    path,
                    dtype=mx.bfloat16,
                    decoding_config=decoding_config,
                    chunk_duration=None,
                )
            elapsed_ms = int((time.perf_counter() - started) * 1000)
            text = getattr(result, "text", "") or ""
            emit({"event": "result", "id": request_id, "text": text, "elapsed_ms": elapsed_ms})
        except Exception as exc:
            emit({"event": "error", "id": request_id, "message": str(exc)})
            traceback.print_exc(file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
