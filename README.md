# Sokki

Minimal local English dictation app for macOS.

Current usable path:

- MLX Parakeet v2 English ASR sidecar (`parakeet-mlx` via `uv`)
- global Right Option hotkey:
  - hold Right Option, speak, release to transcribe/insert
  - tap Right Option, speak, pause or tap again to transcribe/insert
- silence auto-stop
- normal Dock app window
- bottom recording overlay
- recent transcript retry/copy from menu
- no telemetry, no cloud app service

First run may download the local model from Hugging Face through `uv`/`parakeet-mlx`. After cache, dictation is local.

## Run

```bash
scripts/run_app.sh
```

Grant:

- Microphone permission
- Accessibility permission

Then focus a text field and use Right Option.

See [PLAN.md](PLAN.md).
