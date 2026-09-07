"""Run with: uv run --no-project Tests/test_mlx_preload.py."""

import importlib.util
import io
from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace
import unittest
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


if __name__ == "__main__":
    unittest.main()
