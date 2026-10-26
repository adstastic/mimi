"""Run with: uv run --no-project Tests/test_mlx_preload.py."""

import importlib.util
import io
import json
import sys
import unittest
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import patch


class PreloadTests(unittest.TestCase):
    def test_ready_requires_evaluated_weights_without_a_recording(self):
        path = Path(__file__).resolve().parents[1] / "Sidecars/mimi_mlx_server.py"
        spec = importlib.util.spec_from_file_location("mimi_mlx_server", path)
        server = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(server)
        events = []
        weights = object()
        model = SimpleNamespace(parameters=lambda: weights)
        core = ModuleType("mlx.core")
        core.bfloat16 = "bfloat16"
        core.eval = lambda value: events.append(("evaluated", value))
        core.synchronize = lambda: None
        core.clear_cache = lambda: None
        mlx = ModuleType("mlx")
        mlx.core = core
        parakeet = ModuleType("parakeet_mlx")
        parakeet.from_pretrained = lambda *args, **kwargs: model
        config = ModuleType("parakeet_mlx.parakeet")
        config.DecodingConfig = lambda **kwargs: kwargs
        config.Greedy = config.SentenceConfig = lambda: None

        def emit(payload):
            if payload["event"] == "ready":
                self.assertIn(("evaluated", weights), events)
            events.append(payload["event"])

        with patch.dict(sys.modules, {
            "mlx": mlx, "mlx.core": core, "parakeet_mlx": parakeet,
            "parakeet_mlx.parakeet": config,
        }), patch.object(sys, "stdin", io.StringIO()), patch.object(server, "emit", emit):
            self.assertEqual(server.main(), 0)
        self.assertEqual(events, ["loading", ("evaluated", weights), "ready"])

    def test_allocator_cache_is_released_at_idle_boundaries(self):
        for shutdown in (False, True):
            with self.subTest(shutdown=shutdown):
                self._assert_allocator_cache_is_released_at_idle_boundaries(shutdown)

    def _assert_allocator_cache_is_released_at_idle_boundaries(self, shutdown):
        path = Path(__file__).resolve().parents[1] / "Sidecars/mimi_mlx_server.py"
        spec = importlib.util.spec_from_file_location("mimi_mlx_server", path)
        server = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(server)
        allocator = SimpleNamespace(active_bytes=0, pending_bytes=0, cache_bytes=0)
        weights = object()
        loads = []
        transcriptions = []
        ready_memory = []
        idle_memory = []

        def evaluate(value):
            self.assertIs(value, weights)
            allocator.active_bytes = 1024
            allocator.pending_bytes += 512

        def synchronize():
            allocator.cache_bytes += allocator.pending_bytes
            allocator.pending_bytes = 0

        def clear_cache():
            allocator.cache_bytes = 0

        def transcribe(path, **kwargs):
            transcriptions.append(path)
            allocator.pending_bytes += 2048
            print("transcription diagnostic")
            if path == "broken.wav":
                raise RuntimeError("decode failed after allocation")
            return SimpleNamespace(text=f"transcript {path} café")

        model = SimpleNamespace(parameters=lambda: weights, transcribe=transcribe)

        def from_pretrained(*args, **kwargs):
            loads.append(model)
            print("loading diagnostic")
            return model

        core = ModuleType("mlx.core")
        core.bfloat16 = "bfloat16"
        core.eval = evaluate
        core.synchronize = synchronize
        core.clear_cache = clear_cache
        mlx = ModuleType("mlx")
        mlx.core = core
        parakeet = ModuleType("parakeet_mlx")
        parakeet.from_pretrained = from_pretrained
        config = ModuleType("parakeet_mlx.parakeet")
        config.DecodingConfig = lambda **kwargs: kwargs
        config.Greedy = config.SentenceConfig = lambda: None
        requests = [
            {"id": index, "command": "transcribe", "path": audio}
            for index, audio in enumerate(("first.wav", "broken.wav", "last.wav"), 1)
        ]
        if shutdown:
            requests.append({"command": "shutdown"})

        class Input(io.StringIO):
            def __next__(self):
                core.synchronize()
                idle_memory.append((allocator.active_bytes, allocator.cache_bytes))
                return super().__next__()

        emit_protocol = server.emit

        def emit(payload):
            if payload["event"] == "ready":
                core.synchronize()
                ready_memory.append((allocator.active_bytes, allocator.cache_bytes))
            emit_protocol(payload)

        output = io.StringIO()
        errors = io.StringIO()
        stdin = Input("".join(json.dumps(request) + "\n" for request in requests))
        with patch.dict(sys.modules, {
            "mlx": mlx, "mlx.core": core, "parakeet_mlx": parakeet,
            "parakeet_mlx.parakeet": config,
        }), patch.object(sys, "stdin", stdin), patch.object(sys, "stdout", output), \
                patch.object(sys, "stderr", errors), patch.object(server, "emit", emit):
            self.assertEqual(server.main(), 0)

        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual(events[:2], [
            {"event": "loading", "model": server.MODEL_ID},
            {"event": "ready", "model": server.MODEL_ID},
        ])
        self.assertEqual(events[3], {
            "event": "error", "id": 2, "message": "decode failed after allocation",
        })
        for index, audio in ((2, "first.wav"), (4, "last.wav")):
            self.assertEqual(events[index]["event"], "result")
            self.assertEqual(events[index]["id"], 1 if index == 2 else 3)
            self.assertEqual(events[index]["text"], f"transcript {audio} café")
            self.assertIsInstance(events[index]["elapsed_ms"], int)
            self.assertGreaterEqual(events[index]["elapsed_ms"], 0)
        self.assertEqual(len(events), 6 if shutdown else 5)
        if shutdown:
            self.assertEqual(events[-1], {"event": "shutdown"})
        self.assertIn("loading diagnostic", errors.getvalue())
        self.assertIn("transcription diagnostic", errors.getvalue())
        self.assertIn("RuntimeError: decode failed after allocation", errors.getvalue())
        self.assertEqual(loads, [model])
        self.assertEqual(transcriptions, ["first.wav", "broken.wav", "last.wav"])
        with self.subTest(boundary="ready"):
            self.assertEqual(ready_memory, [(1024, 0)])
        for index, memory in enumerate(idle_memory):
            with self.subTest(boundary="stdin", read=index):
                self.assertEqual(memory, (1024, 0))
        with self.subTest(boundary="completed loop"):
            self.assertEqual((allocator.active_bytes, allocator.cache_bytes), (1024, 0))


if __name__ == "__main__":
    unittest.main()
