# Sokki Implementation Plan

## Goal

Build the smallest useful macOS dictation app for Adi:

- local-only English ASR
- very low perceived start latency
- global hotkeys for hold-to-record and tap-to-toggle
- configurable silence auto-stop
- configurable post-paste Return/Enter
- recent transcript retry when insertion fails
- no telemetry, no cloud, no product cruft

Primary target: Apple Silicon Mac, macOS 14+.

## Non-goals

- No multi-user/product dashboard.
- No cloud ASR or cloud LLM.
- No meeting recorder, YouTube transcription, calendar, chat, transforms, analytics, updates, accounts, licensing, or telemetry.
- No App Store packaging.
- No true live typing in v1; final paste after utterance is enough. Live overlay can show level/state.

## Product behavior

### Hotkey mode

One primary global hotkey supports both gestures:

- key down: immediately start capture using pre-roll buffer
- key up before `tapThresholdMs`: keep recording in toggle mode
- key down while toggle recording: stop, transcribe, insert
- key held beyond `holdThresholdMs`: hold-to-record mode
- key up after hold mode: stop, transcribe, insert
- Escape while recording: cancel capture

Default key: Right Option, configurable later.

### Silence stop

While recording, app tracks microphone level.

Config:

- `silenceThresholdDb` default around `-38 dBFS`
- `silenceDurationMs` default `1000`
- `minUtteranceMs` default `350`
- `preRollMs` default `700`

When level stays below threshold for silence duration, stop automatically and process.

### Ambient mode

Stretch but planned from same audio core:

- mic stays running
- ring buffer keeps pre-roll
- speech start detected by threshold crossing for `startWindowMs`
- speech end detected by silence duration
- segment transcribed and inserted automatically
- cooldown prevents rapid accidental re-trigger after paste

Ambient mode will be opt-in from menu/settings.

### Insertion

Insertion strategy, in order:

1. Direct Accessibility insertion into focused text field when possible.
2. Clipboard + Cmd-V fallback, with clipboard restore.
3. Retry hotkey can re-insert last transcript using Unicode typing to avoid clipboard.

If no focused input exists or paste fails:

- overlay shows error
- transcript kept as `lastTranscript`
- retry hotkey attempts insertion again
- menu has “Copy Last Transcript” as manual fallback

### Auto Enter

Config:

- `off`
- `always`
- `appAllowlist`

Allowlist stored as bundle IDs, default candidates:

- `com.todesktop.230313mzl4w4u92` Cursor if current bundle id matches installed app
- `com.microsoft.VSCode`
- `com.mitchellh.ghostty`
- `com.googlecode.iterm2`
- `dev.warp.Warp-Stable`
- `com.apple.Terminal`

After successful text insertion, sleep `postPasteEnterDelayMs` default `150`, then synthesize Return key.

### Overlay

Small bottom-center NSPanel, no focus stealing.

States:

- hidden idle
- listening: red dot, waveform/level bar, elapsed time
- processing: spinner, “Transcribing…”
- inserted: checkmark, maybe faded transcript preview
- error: “Insert failed — retry ⌥⇧V”

Implementation: `NSPanel` + `NSHostingView` + SwiftUI pill.

### Menu bar/settings

Bare menu bar app:

- Enabled
- Ambient Mode
- Model status
- Silence threshold/delay summary
- Auto Enter mode summary
- Retry Last Insert
- Copy Last Transcript
- Settings…
- Quit

Settings window: plain SwiftUI form.

## ASR model

Preferred backend default: `mlxParakeetV2` (MLX Parakeet v2, local sidecar candidate).

Slice 1 benchmark compares:

- MLX Parakeet v2 sidecar
- FluidAudio/CoreML Parakeet v2

No ASR backend dependency is included in Slice 0. After Slice 1 benchmark, wire the chosen local backend behind `ASRService` and keep it warm until quit.

Reasons:

- v2 is English-only; avoids Parakeet v3 multilingual hallucinations.
- Local-only transcription; no telemetry or cloud ASR. First-run model/package download may use network until cached.
- Batch transcription should be fast enough for short dictation.

Open question for Slice 1: exact sidecar/API shape and benchmark winner must be verified before backend integration.

## Codebase shape

Keep files small. Target ~10-14 source files.

```text
Sokki/
  Package.swift
  README.md
  PLAN.md
  scripts/
    build_app.sh
    run_app.sh
  Sources/Sokki/
    SokkiApp.swift
    Config.swift
    AppPaths.swift
    ASRService.swift
    AudioCapture.swift
    SilenceDetector.swift
    HotkeyMonitor.swift
    DictationController.swift
    TextInserter.swift
    HistoryStore.swift
    OverlayWindow.swift
    SettingsView.swift
    MenuBarController.swift
  Tests/SokkiTests/
    SilenceDetectorTests.swift
    HotkeyStateMachineTests.swift
    HistoryStoreTests.swift
```

No nested feature modules unless code growth forces it.

## Component responsibilities

### `Config.swift`

`Codable`/UserDefaults-backed config:

- preferred backend default `mlxParakeetV2`
- local/no-telemetry defaults, cloud transcription off, model download explicit
- hotkey keyCode/modifiers or fixed first version
- tap/hold thresholds
- silence threshold/delay
- pre-roll ms
- ambient enabled
- auto-enter mode + allowlist
- insertion preference
- history limit

### `AppPaths.swift`

Creates:

- `~/Library/Application Support/Sokki/`
- `history.jsonl`
- temp audio dir if needed

No telemetry paths. First-run model download/cache paths are explicit.

### `ASRService.swift`

Actor.

- `prepare()` loads the selected local Parakeet v2 backend once.
- `transcribe(samples:)` or `transcribe(wavURL:)` returns text.
- Serializes transcription calls.
- Emits model status.

### `AudioCapture.swift`

Owns AVAudioEngine.

- starts engine at app launch if mic permission granted
- keeps ring buffer of last `preRollMs`
- records current segment when commanded
- computes current RMS/dB every audio callback
- writes final segment to WAV or returns `[Float]`

Prefer in-memory float samples if selected backend supports direct sample transcription; otherwise write temp WAV.

### `SilenceDetector.swift`

Pure testable state machine:

- tracks above/below threshold
- returns `.speechStarted`, `.speechEnded`, `.none`
- handles min utterance and cooldown

### `HotkeyMonitor.swift`

CGEventTap.

- default Right Option or user-configured key
- implements same-key tap/hold/toggle state machine
- calls controller: `hotkeyDown`, `hotkeyUp`, `cancel`
- no double-tap requirement

### `DictationController.swift`

Main orchestrator.

States:

```swift
idle
recording(mode: .hold | .toggle | .ambient)
processing
inserted
error
```

Coordinates:

- capture start/stop
- silence auto-stop
- ASR
- history
- insert
- overlay state
- retry last transcript

### `TextInserter.swift`

Insertion methods:

- `insertAX(text:)`
- `insertClipboard(text:, restore:)`
- `typeUnicode(text:)`
- `pressReturn()`

Bundle ID allowlist check for auto-enter.

### `HistoryStore.swift`

Minimal recent history.

- in-memory `[TranscriptEntry]`
- append to JSONL optional from day one
- load last N on launch
- `lastTranscript` always available

### `OverlayWindow.swift`

NSPanel + SwiftUI pill.

- bottom center by default
- optional notch-ish top center later
- non-activating
- all spaces/fullscreen

### `SettingsView.swift`

Bare SwiftUI form bound to config.

## Build/package plan

Use Swift Package for source simplicity, plus script to make `.app` bundle.

`Package.swift`:

- executable target `Sokki`
- test target `SokkiTests`
- add ASR dependency only after Slice 1 benchmark decision

`scripts/build_app.sh`:

1. `swift build -c release`
2. create `build/Sokki.app/Contents/{MacOS,Resources}`
3. copy executable
4. write `Info.plist`
5. include mic usage string
6. ad-hoc sign:

```bash
codesign --force --deep --sign - build/Sokki.app
```

`scripts/run_app.sh` builds and opens app.

Local signing only. No Developer ID needed for personal testing.

## Permissions

App needs:

- Microphone permission for AVAudioEngine
- Accessibility permission for CGEventTap and insertion/fallback paste

Settings/menu should expose permission status and “Open System Settings” buttons if easy; otherwise README documents it.

## Validation plan

### Automated tests

- Silence detector threshold/duration/cooldown.
- Hotkey state machine:
  - hold start/stop
  - tap starts toggle
  - second tap stops
  - Escape cancels
- History append/load last N.
- Auto-enter allowlist logic.

### Manual checks

1. Build app and grant permissions.
2. Confirm selected local Parakeet v2 backend loads.
3. Hold hotkey, speak, release → text inserts.
4. Tap hotkey, speak, silence auto-stops → text inserts.
5. Tap hotkey, speak, tap again → text inserts.
6. With no focused input, insert fails visibly, retry works after focusing field.
7. Auto-enter works in selected coding app only.
8. Ambient mode off by default.
9. Ambient mode on: starts on voice, stops on silence, uses pre-roll.
10. After model/package cache exists, no outbound expected during dictation.

## Implementation slices

### Slice 0 — repo skeleton

- `Package.swift`
- app entry
- build/run scripts
- menu bar app boots
- settings window opens

Verify: `scripts/run_app.sh` launches menu bar app.

### Slice 1 — ASR benchmark + warm load

- benchmark MLX Parakeet v2 sidecar vs FluidAudio/CoreML v2
- keep preferred config default `mlxParakeetV2` unless explicit benchmark decision changes it
- `ASRService.prepare()` loads chosen local Parakeet v2 backend
- CLI/menu test action transcribes bundled/sample WAV or chosen file

Verify: known English WAV transcribes locally.

### Slice 2 — audio capture + hotkey

- AVAudioEngine ring buffer
- same-key hotkey state machine
- hold/tap start-stop capture
- save temp WAV for inspection

Verify: hotkey records audio with first syllable captured.

### Slice 3 — end-to-end dictation

- capture → ASR → insertion
- overlay states
- history last transcript

Verify: dictate into TextEdit/Cursor.

### Slice 4 — silence auto-stop + auto-enter

- configurable silence threshold/delay
- app allowlist Return
- retry hotkey/menu action

Verify: tap start, stop by silence, paste and Enter in coding app.

### Slice 5 — ambient mode

- always-on VAD segmenting from ring buffer
- cooldown/min utterance
- overlay only when active

Verify: hands-free local dictation without hotkey.

### Slice 6 — polish

- settings persistence
- permission helper buttons
- README install/use docs
- optional icon
- final local build script

## Risks and mitigations

### ASR API/sidecar drift

Mitigation: pin exact dependency or sidecar version after Slice 1 benchmark. If API differs, adapt once in `ASRService` only.

### TCC permission flakiness

Mitigation: always run as stable `.app` bundle with same bundle ID and ad-hoc signing. Avoid running raw executable for manual testing.

### Audio callback performance

Mitigation: audio callback only appends samples and updates atomic/current RMS. No file IO, no ASR, no allocations beyond bounded ring if possible.

### Clipboard privacy

Mitigation: direct AX first, Unicode typing retry, clipboard fallback restores clipboard and is documented.

### Ambient false positives

Mitigation: thresholds, min utterance, cooldown, ambient off by default, visible armed state.

### AirPods/Bluetooth latency

Mitigation: support input device selector later if needed; document built-in/USB mic preferred for lowest start latency.

## Compact handoff prompt

Build `Sokki` from `PLAN.md`: smallest macOS menu-bar Swift app for local English dictation. Preferred ASR config default is `mlxParakeetV2`; Slice 1 benchmarks MLX Parakeet v2 sidecar vs FluidAudio/CoreML v2 before backend integration. Implement global same-key hotkey supporting hold-to-record and tap-to-toggle. Use always-running AVAudioEngine with pre-roll ring buffer. Stop on configurable silence. Insert transcript via AX/clipboard fallback, keep recent transcript/history, retry insertion via non-clipboard Unicode typing. Optional app-allowlisted auto Return after paste. Bottom overlay. No telemetry/cloud/product cruft. Follow slices 0-4 first, then ambient mode slice 5.
