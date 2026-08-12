# mimi

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
- independently configurable silence auto-stop, stop detection mode, microphone input, and pre/post-paste keystrokes and delays for shortcut and ambient dictation
- paste presets: named pre/post-paste keystroke sets per target app, switched in Settings or cycled with a global shortcut (default Control-Option-P) with an overlay showing the active preset
- menu bar app with a full settings window available on demand
- bottom recording overlay with live partials for Apple SpeechTranscriber
- transcript stays copied to clipboard after dictation
- latest-transcript correction from menu bar or configurable global shortcut (default Control-Option-C), with vocabulary-rule preview
- canonical user-editable config at `~/.config/mimi/config.json`
- no telemetry, no cloud app service

Apple SpeechTranscriber may download Apple-managed on-device speech assets. MLX fallback may download the local model from Hugging Face through `uv`/`parakeet-mlx`. After caches/assets exist, dictation is local.

## Config

Mimi reads and atomically writes `~/.config/mimi/config.json`. On first launch it migrates existing settings and vocabulary from `UserDefaults`. Use the menu-bar commands **Open Config File** and **Reload Config** after manual edits.

Missing keys use defaults. Unknown keys, wrong types, invalid ranges, and conflicting vocabulary aliases reject reload; Mimi keeps its last-good configuration and does not overwrite the invalid file.

Vocabulary pairs group observed forms under exact output:

```json
{
  "vocabulary": [
    {
      "from": ["Jason"],
      "to": "JSON"
    },
    {
      "from": ["nema", "neema"],
      "to": "nima"
    }
  ]
}
```

`to` also acts as a case-insensitive self-alias, preserving canonical casing. Delete a pairing to disable it.

### Paste presets

`pastePresets` holds named pre/post-paste keystroke sets. `activePastePresetName` selects one; omit it (or pick **Manual** in Settings) to use `dictationPasteSettings` / `ambientPasteSettings` instead. An active preset overrides both. Names must be unique, non-empty, and not `Manual`.

```json
{
  "activePastePresetName": "TUICR",
  "pastePresets": [
    {
      "name": "TUICR",
      "paste": {
        "prePasteKeystroke": { "keyCode": 8, "modifierFlagsRaw": 0 },
        "postPasteKeystroke": { "keyCode": 36, "modifierFlagsRaw": 0 },
        "prePasteDelayMilliseconds": 150,
        "postPasteDelayMilliseconds": 150
      }
    }
  ]
}
```

Defaults ship **Terminal agent** (paste → Return), **RevDiff** (Return → paste → Return), and **TUICR** (C → paste → Return). `pastePresetShortcut` cycles Manual → each preset → Manual.

Correcting the latest transcript learns each separate replacement across multiple sentences. Insertions, deletions, and punctuation-only edits do not create vocabulary rules.

## Run

```bash
scripts/run_app.sh
```

Safe streaming smoke test (no UI focus stealing):

```bash
scripts/smoke_streaming.sh
```

Prototype voiceprint extraction:

```bash
swift run MimiSmoke voiceprint-enroll /path/to/my-voice-1.wav /path/to/my-voice-2.wav [--threshold 0.78]
swift run MimiSmoke voiceprint-verify /path/to/check.wav
swift run MimiSmoke voiceprint-extract /path/to/mixed.wav --output /tmp/owner-only.wav
```

On first launch, Settings opens so you can grant required permissions. After setup, click the mimi logo in the menu bar to reopen Settings or quit the app. The settings window also has My Voice → Enroll / Verify / Reset. If a profile exists, mimi diarizes recordings, keeps matching speaker segments, then transcribes only those.

Grant:

- Microphone permission
- Accessibility permission
- Input Monitoring permission

Then focus a text field and use the dictation shortcut.

See [PLAN.md](PLAN.md).
