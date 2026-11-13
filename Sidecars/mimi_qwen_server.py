#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11,<3.13"
# dependencies = ["mlx-qwen3-asr==0.4.4"]
# ///

import contextlib
import json
import os
import sys
import time
import traceback

MODEL_ID = os.environ.get("MIMI_QWEN_MODEL", "Qwen/Qwen3-ASR-1.7B")


def emit(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    emit({"event": "loading", "model": MODEL_ID})
    try:
        with contextlib.redirect_stdout(sys.stderr):
            import mlx.core as mx
            from mlx_qwen3_asr import Session

            session = Session(model=MODEL_ID)
            mx.eval(session.model.parameters())
            mx.synchronize()
            mx.clear_cache()
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
                result = session.transcribe(path, language="English", context=request.get("context", ""))
            elapsed_ms = int((time.perf_counter() - started) * 1000)
            text = getattr(result, "text", "") or ""
            emit({"event": "result", "id": request_id, "text": text, "elapsed_ms": elapsed_ms})
        except Exception as exc:
            emit({"event": "error", "id": request_id, "message": str(exc)})
            traceback.print_exc(file=sys.stderr)
        finally:
            with contextlib.redirect_stdout(sys.stderr):
                mx.synchronize()
                mx.clear_cache()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
