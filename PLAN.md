# Sokki Plan

## Current baseline

Sokki is a minimal macOS Dock app for local dictation.

Implemented:

- SwiftUI settings window.
- Bottom overlay for recording/transcribing/insert/error.
- Right Command global hotkey:
  - hold → record while held → release to transcribe/paste
  - tap → start recording → tap again or silence stop to transcribe/paste
- Always-running `AVAudioEngine` capture with pre-roll ring buffer.
- MLX Parakeet v2 sidecar kept warm through `uv run --python 3.12 --script`.
- Local batch transcription path: record WAV → sidecar transcribes → paste.
- Clipboard paste with restore; retry last insert uses Unicode typing.
- Recent transcript shown with Retry/Copy buttons.
- Independent toggles:
  - end recording on silence
  - press Enter after pasting
- Configurable silence threshold and silence duration; default stop delay is 2.0s.
- Permission status lights + buttons for Microphone, Accessibility, Input Monitoring.
- Stable `/Applications/Sokki.app` build signed with Apple Development identity when available.
- No telemetry, no cloud ASR. First-run dependency/model download may use network until cached.

Current verification commands:

```bash
swift test
scripts/build_app.sh
```

Current manual install/run:

```bash
pkill -x Sokki || true
rm -rf /Applications/Sokki.app
cp -R build/Sokki.app /Applications/Sokki.app
open /Applications/Sokki.app
```

## Next milestone: Apple on-device streaming backend

Goal: compare Apple built-in speech streaming against MLX Parakeet v2 batch dictation, without breaking the current Parakeet path.

Questions to answer with code, not guesses:

1. Can Apple Speech stream partial English transcripts locally on this Mac?
2. Is startup/first-token latency better than current MLX batch path?
3. Is final accuracy good enough for coding/chat dictation?
4. Can Sokki show live partial text while still pasting only final text?

## Backend strategy

Add backend enum:

```swift
enum ASRBackend {
    case mlxParakeetV2
    case appleSpeechOnDevice
}
```

Keep MLX Parakeet as known-good final/batch fallback.

Implement Apple backend with the stable Speech framework first:

- `SFSpeechRecognizer(locale: Locale(identifier: "en_US"))`
- `SFSpeechAudioBufferRecognitionRequest`
- `request.requiresOnDeviceRecognition = true`
- fail clearly if `supportsOnDeviceRecognition == false`
- no cloud fallback
- consume audio buffers directly from `AudioCapture`
- emit partial and final transcript events

If the local SDK exposes newer SpeechAnalyzer/SpeechTranscriber APIs, spike them after SFSpeech works. Do not make that the first dependency unless SFSpeech cannot satisfy local streaming.

## Required architecture changes

### `ASRService`

Split current service into a small backend protocol:

```swift
protocol BatchASRBackend {
    func prepare() async throws
    func transcribe(audioURL: URL) async throws -> String
}

protocol StreamingASRBackend {
    func prepare() async throws
    func startStream(onPartial: @escaping @MainActor (String) -> Void) async throws
    func append(_ buffer: AVAudioPCMBuffer) async throws
    func finishStream() async throws -> String
    func cancelStream() async
}
```

Adapters:

- `MLXParakeetBackend`: existing JSON-lines sidecar batch path.
- `AppleSpeechStreamingBackend`: on-device Apple streaming path.

### `AudioCapture`

Current capture writes samples to WAV after recording. Add live buffer fan-out:

- keep existing ring buffer + WAV finalization for MLX
- while recording, forward captured `AVAudioPCMBuffer` copies to current streaming backend
- keep callback work tiny: append/copy only, no ASR in audio callback

### `DictationController`

Behavior by selected backend:

- MLX Parakeet:
  - existing flow: record → finish WAV → transcribe → paste
- Apple Speech:
  - on recording start: `startStream`
  - during recording: append buffers
  - partial events update overlay/settings live transcript
  - on stop/silence: `finishStream` → paste final

Overlay:

- listening: show level + elapsed
- streaming: show partial transcript line
- processing: only if backend finalization still running

Settings:

- backend picker: MLX Parakeet v2 / Apple Speech on-device
- show backend status:
  - MLX loaded
  - Apple on-device supported / missing / permission needed

## End-to-end testing plan the agent can run

Do not rely on Adi speaking manually. Add test hooks/scripts.

### 1. Synthetic audio fixture

Generate deterministic English audio with macOS `say`:

```bash
say -o /tmp/sokki-streaming-smoke.aiff "sokki streaming smoke test please press enter after paste"
afconvert /tmp/sokki-streaming-smoke.aiff -f WAVE -d LEF32@16000 /tmp/sokki-streaming-smoke.wav
```

### 2. Add smoke executable target

Add SwiftPM executable target:

```text
Sources/SokkiSmoke/
  main.swift
```

Modes:

```bash
swift run SokkiSmoke mlx-file /tmp/sokki-streaming-smoke.wav
swift run SokkiSmoke apple-stream-file /tmp/sokki-streaming-smoke.wav
```

`apple-stream-file` must:

- read the WAV file
- split it into small `AVAudioPCMBuffer` chunks, e.g. 100ms
- feed chunks into `AppleSpeechStreamingBackend.append`
- collect partials and final
- assert final contains key terms: `sokki`, `streaming`, `smoke`, `test`
- print timings:
  - prepare ms
  - first partial ms after first audio buffer
  - final ms after last buffer

This proves streaming backend without physical microphone.

### 3. Add app-level smoke command

Add hidden/debug CLI flag to app executable or smoke target:

```bash
swift run SokkiSmoke end-to-end-textedit /tmp/sokki-streaming-smoke.wav --backend apple
```

Flow:

1. Open TextEdit with a temporary untitled document using AppleScript.
2. Feed synthetic WAV through chosen backend.
3. Use `TextInserter` to paste final text into TextEdit.
4. If press-enter enabled, verify newline exists.
5. Read TextEdit document text using AppleScript and assert expected words.
6. Close document without saving.

This proves: backend → final transcript → insertion, without user dictation.

### 4. Live app smoke

After automated smoke passes:

```bash
scripts/build_app.sh
rm -rf /Applications/Sokki.app
cp -R build/Sokki.app /Applications/Sokki.app
open /Applications/Sokki.app
```

Agent can verify process + logs:

```bash
pgrep -fl 'Sokki|sokki_mlx|Python.*sokki'
log show --predicate 'process == "Sokki"' --last 2m --style compact | tail -80
```

Manual user check only after automated smoke is green.

## Implementation slices

### Slice A — backend protocol extraction

- Introduce backend protocols.
- Move current MLX sidecar code into `MLXParakeetBackend`.
- `ASRService` delegates to selected backend.
- No behavior change.

Verify:

```bash
swift test
scripts/build_app.sh
swift run SokkiSmoke mlx-file /tmp/sokki-streaming-smoke.wav
```

### Slice B — synthetic smoke harness

- Add `SokkiSmoke` target.
- Add WAV reader/chunker utilities.
- Add MLX file smoke first to prove harness.

Verify: MLX smoke transcribes generated `say` audio.

### Slice C — Apple Speech streaming backend

- Implement `AppleSpeechStreamingBackend`.
- Force local/on-device recognition.
- Surface unsupported/missing permission status clearly.
- Implement `SokkiSmoke apple-stream-file`.

Verify:

```bash
swift run SokkiSmoke apple-stream-file /tmp/sokki-streaming-smoke.wav
```

Pass criteria:

- at least one partial transcript before final
- final transcript contains expected keywords
- printed first-partial and finalization timings
- no cloud fallback

### Slice D — app integration

- Backend picker in Settings.
- When Apple backend selected, partial transcript appears in overlay and settings.
- Final paste path uses same `TextInserter`.
- Existing MLX path still works.

Verify:

```bash
swift test
scripts/build_app.sh
swift run SokkiSmoke end-to-end-textedit /tmp/sokki-streaming-smoke.wav --backend apple
swift run SokkiSmoke end-to-end-textedit /tmp/sokki-streaming-smoke.wav --backend mlx
```

### Slice E — latency mini-metrics

Collect local-only timings in memory:

- hotkey keyDown → first audio buffer recorded
- stop requested → transcription final text
- final text → paste complete
- Apple only: first audio buffer → first partial

Show simple recent metrics section in SwiftUI, not external telemetry.

No files/network upload. In-memory only initially.

## Risks

### Apple on-device availability

`SFSpeechRecognizer` may not support on-device recognition for the current locale/OS state. If unsupported, fail clearly and keep MLX default.

### Apple Speech permission friction

Speech recognition may require an additional permission beyond mic/input monitoring. Settings should show actionable status and buttons where possible.

### Partial transcript instability

Partial text can revise itself. Do not type partials into target apps initially. Show partials only in overlay/settings; paste final only.

### Streaming accuracy vs Parakeet

Apple may be faster but less accurate for code-ish prose. Keep backend picker and benchmark output.

### Test realism

`say` synthetic audio is not the same as live mic. It is still good enough for repeatable backend/insertion smoke. Final live dogfood comes after automated smoke.

## Compact handoff prompt

Continue Sokki from `PLAN.md`. Current app works with MLX Parakeet v2 batch dictation. Next milestone: add Apple on-device streaming backend without regressing MLX. First extract backend protocol and add `SokkiSmoke` target. Implement deterministic e2e tests with generated `say` WAV: `mlx-file`, `apple-stream-file`, and `end-to-end-textedit`. Apple backend must use local/on-device recognition only (`requiresOnDeviceRecognition = true`) and surface unsupported status instead of falling back to cloud. Show partial transcripts in overlay/settings, paste final only. After automated smoke passes, build/install `/Applications/Sokki.app` for manual dogfood.
