"""Run with: uv run --no-project Tests/test_qwen_sidecar.py."""

import importlib.util
import io
import json
import sys
import threading
import unittest
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import patch


class QwenSidecarTests(unittest.TestCase):
    def run_server(self, requests, fail_load=False):
        path = Path(__file__).resolve().parents[1] / "Sidecars/mimi_qwen_server.py"
        spec = importlib.util.spec_from_file_location("mimi_qwen_server", path)
        server = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(server)
        calls = []
        weights = object()
        memory = SimpleNamespace(pending=0, cache=0)
        main_thread = threading.get_ident()

        def evaluate(value):
            self.assertIs(value, weights)
            self.assertEqual(threading.get_ident(), main_thread)
            calls.append("eval")
            memory.pending += 512

        def synchronize():
            memory.cache += memory.pending
            memory.pending = 0
            calls.append("synchronize")

        def clear_cache():
            memory.cache = 0
            calls.append("clear_cache")

        def transcribe(path, **kwargs):
            self.assertEqual(threading.get_ident(), main_thread)
            calls.append(("transcribe", path, kwargs))
            memory.pending += 1024
            print("inference diagnostic")
            if path == "broken.wav":
                raise RuntimeError("decode failed")
            return SimpleNamespace(text=f"transcript {path} café")

        def session(**kwargs):
            self.assertEqual(threading.get_ident(), main_thread)
            calls.append(("Session", kwargs))
            print("loading diagnostic")
            if fail_load:
                raise RuntimeError("load failed")
            return SimpleNamespace(model=SimpleNamespace(parameters=lambda: weights), transcribe=transcribe)

        core = ModuleType("mlx.core")
        core.eval = evaluate
        core.synchronize = synchronize
        core.clear_cache = clear_cache
        mlx = ModuleType("mlx")
        mlx.core = core
        qwen = ModuleType("mlx_qwen3_asr")
        qwen.Session = session
        boundaries = []

        class Input(io.StringIO):
            def __next__(self):
                boundaries.append((memory.pending, memory.cache))
                return super().__next__()

        emit_protocol = server.emit

        def emit(payload):
            if payload["event"] == "ready":
                self.assertEqual(calls[-3:], ["eval", "synchronize", "clear_cache"])
                self.assertEqual((memory.pending, memory.cache), (0, 0))
            emit_protocol(payload)

        output, errors = io.StringIO(), io.StringIO()
        stdin = Input("".join(json.dumps(request) + "\n" for request in requests))
        with patch.dict(sys.modules, {"mlx": mlx, "mlx.core": core, "mlx_qwen3_asr": qwen}), \
                patch.object(sys, "stdin", stdin), patch.object(sys, "stdout", output), \
                patch.object(sys, "stderr", errors), patch.object(server, "emit", emit):
            code = server.main()
        self.assertTrue(all(boundary == (0, 0) for boundary in boundaries))
        self.assertEqual((memory.pending, memory.cache), (0, 0))
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        return code, events, calls, errors.getvalue()

    def test_session_is_preloaded_once_and_requests_recover_with_clean_stdout(self):
        for shutdown in (False, True):
            with self.subTest(shutdown=shutdown):
                requests = [
                    {"id": 1, "command": "transcribe", "path": "first.wav", "context": "Vocabulary: PyTorch, Mimi."},
                    {"id": 2, "command": "transcribe", "path": "broken.wav"},
                    {"id": 3, "command": "transcribe", "path": "last.wav"},
                ]
                if shutdown:
                    requests += [{"command": "shutdown"}, {"id": 4, "command": "transcribe", "path": "never.wav"}]
                code, events, calls, errors = self.run_server(requests)
                self.assertEqual(code, 0)
                self.assertEqual(events[:2], [
                    {"event": "loading", "model": "Qwen/Qwen3-ASR-1.7B"},
                    {"event": "ready", "model": "Qwen/Qwen3-ASR-1.7B"},
                ])
                self.assertEqual([call for call in calls if isinstance(call, tuple)], [
                    ("Session", {"model": "Qwen/Qwen3-ASR-1.7B"}),
                    ("transcribe", "first.wav", {"language": "English", "context": "Vocabulary: PyTorch, Mimi."}),
                    ("transcribe", "broken.wav", {"language": "English", "context": ""}),
                    ("transcribe", "last.wav", {"language": "English", "context": ""}),
                ])
                self.assertEqual(events[2]["text"], "transcript first.wav café")
                self.assertEqual(events[2]["id"], 1)
                self.assertEqual(events[3], {"event": "error", "id": 2, "message": "decode failed"})
                self.assertEqual(events[4]["text"], "transcript last.wav café")
                self.assertEqual(events[4]["id"], 3)
                self.assertIsInstance(events[4]["elapsed_ms"], int)
                self.assertEqual(len(events), 6 if shutdown else 5)
                if shutdown:
                    self.assertEqual(events[-1], {"event": "shutdown"})
                self.assertIn("loading diagnostic", errors)
                self.assertIn("inference diagnostic", errors)
                self.assertIn("RuntimeError: decode failed", errors)

    def test_load_failure_exits_without_ready(self):
        code, events, _, errors = self.run_server([], fail_load=True)
        self.assertEqual(code, 1)
        self.assertEqual([event["event"] for event in events], ["loading", "error"])
        self.assertIn("load failed", events[1]["message"])
        self.assertIn("RuntimeError: load failed", errors)

    def test_invalid_requests_do_not_poison_next_transcription(self):
        code, events, _, _ = self.run_server([
            {"id": 1, "command": "other"},
            {"id": 2, "command": "transcribe"},
            {"id": 3, "command": "transcribe", "path": "valid.wav"},
        ])
        self.assertEqual(code, 0)
        self.assertEqual([event["event"] for event in events], ["loading", "ready", "error", "error", "result"])
        self.assertEqual(events[-1]["text"], "transcript valid.wav café")


if __name__ == "__main__":
    unittest.main()
