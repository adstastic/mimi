"""Opt in with MIMI_TEST_REAL_QWEN=1 uv run --offline --no-project --python 3.12 python Tests/test_qwen_vocabulary_integration.py.

Uses one cached model in a separate sidecar, never the running app or microphone.
Set MIMI_QWEN_TEST_SIDECAR to exercise an installed sidecar instead.
"""

import array
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile
import unittest
import wave


@unittest.skipUnless(os.environ.get("MIMI_TEST_REAL_QWEN") == "1", "requires cached real Qwen model")
class QwenVocabularyIntegrationTests(unittest.TestCase):
    def test_synthetic_nonspeech_does_not_become_vocabulary(self):
        sidecar = Path(os.environ.get(
            "MIMI_QWEN_TEST_SIDECAR",
            Path(__file__).resolve().parents[1] / "Sidecars/mimi_qwen_server.py",
        ))
        artifacts = Path(tempfile.mkdtemp(prefix="mimi-qwen-vocabulary-", dir="/tmp"))
        print(f"artifacts={artifacts}", flush=True)
        vocabulary = ["Cobalt", "Marigold", "Velvet", "Telescope"]
        context = "Vocabulary: " + ", ".join(vocabulary) + "."
        requests = []
        cases = {}
        rng = random.Random(431)
        for duration in (0.25, 1.0):
            for kind in ("silence", "low_noise"):
                samples = array.array("h", (
                    0 if kind == "silence" else rng.randint(-3, 3)
                    for _ in range(int(16000 * duration))
                ))
                path = artifacts / f"{kind}_{duration}.wav"
                with wave.open(str(path), "wb") as audio:
                    audio.setnchannels(1)
                    audio.setsampwidth(2)
                    audio.setframerate(16000)
                    audio.writeframes(samples.tobytes())
                for hints in (False, True):
                    request_id = f"{kind}_{duration}_hints_{hints}"
                    cases[request_id] = hints
                    requests.append({
                        "id": request_id,
                        "command": "transcribe",
                        "path": str(path),
                        "context": context if hints else "",
                    })
        for repeat in range(2):
            request = dict(requests[1], id=f"silence_0.25_hints_repeat_{repeat}")
            requests.append(request)
            cases[request["id"]] = True
        requests.append({"command": "shutdown"})
        payload = "".join(json.dumps(request) + "\n" for request in requests)
        (artifacts / "requests.jsonl").write_text(payload)
        env = dict(os.environ, HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1")
        env.pop("MIMI_QWEN_MODEL", None)
        with (artifacts / "stderr.log").open("w") as errors:
            process = subprocess.run(
                ["uv", "run", "--offline", "--python", "3.12", "--script", str(sidecar)],
                input=payload, text=True, stdout=subprocess.PIPE, stderr=errors,
                env=env, timeout=600,
            )
        (artifacts / "stdout.jsonl").write_text(process.stdout)
        print(process.stdout, end="", flush=True)
        self.assertEqual(process.returncode, 0, f"sidecar failed; see {artifacts}")
        events = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual(events[0]["event"], "loading")
        self.assertEqual(events[1]["event"], "ready", f"model not ready; see {artifacts}")
        self.assertEqual(events[-1]["event"], "shutdown")
        results = {event["id"]: event for event in events if event["event"] == "result"}
        self.assertEqual(set(results), set(cases), f"missing results; see {artifacts}")
        for request_id in cases:
            with self.subTest(case=request_id):
                text = results[request_id]["text"]
                self.assertFalse(
                    all(term.casefold() in text.casefold() for term in vocabulary),
                    f"all synthetic vocabulary terms echoed from nonspeech: {text!r}",
                )


if __name__ == "__main__":
    unittest.main()
