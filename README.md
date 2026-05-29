# Sokki

Minimal local English dictation app for macOS.

Current usable path:

- Apple SpeechTranscriber streaming backend by default
- MLX Parakeet v2 English ASR sidecar fallback (`parakeet-mlx` via `uv`)
- global Right Command hotkey:
  - hold Right Command, speak, release to transcribe/insert
  - tap Right Command, speak, pause or tap again to transcribe/insert
  - press Escape while recording to cancel
- silence auto-stop
- optional ambient VAD mode that keeps mic armed and uses Apple SpeechDetector to start/stop on speech
- independently configurable silence auto-stop and Return-after-paste
- normal Dock app window
- bottom recording overlay with live partials for Apple SpeechTranscriber
- transcript stays copied to clipboard after dictation
- recent transcript copy button
- no telemetry, no cloud app service

Apple SpeechTranscriber may download Apple-managed on-device speech assets. MLX fallback may download the local model from Hugging Face through `uv`/`parakeet-mlx`. After caches/assets exist, dictation is local.

## Run

```bash
scripts/run_app.sh
```

Safe streaming smoke test (no UI focus stealing):

```bash
scripts/smoke_streaming.sh
```

Grant:

- Microphone permission
- Accessibility permission

Then focus a text field and use Right Command.

See [PLAN.md](PLAN.md).
