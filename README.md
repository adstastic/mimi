# Sokki

Minimal local English dictation app for macOS.

Planned core:

- preferred local ASR backend default: `mlxParakeetV2` (MLX Parakeet v2)
- Slice 1 benchmark: MLX Parakeet v2 sidecar vs FluidAudio/CoreML v2
- global hotkey: hold-to-record and tap-to-toggle
- configurable silence auto-stop
- configurable post-paste Return
- recent transcript retry
- bottom recording overlay
- no telemetry, no cloud, runtime network off by default

Slice 0 builds menu bar skeleton only. No ASR, audio, hotkeys, or overlay yet.

```bash
swift test
scripts/build_app.sh
scripts/run_app.sh
```

See [PLAN.md](PLAN.md).
