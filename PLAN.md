# Sokki Plan

## Current baseline

Sokki is a minimal macOS Dock app for local dictation.

Implemented:

- SwiftUI settings window.
- Bottom overlay for recording/transcribing/insert/error.
- Right Command global hotkey:
  - hold → record while held → release to transcribe/paste
  - tap → start recording → tap again or silence stop to transcribe/paste
- Mic starts only while recording by default; optional ambient mode keeps mic armed for threshold VAD.
- Apple SpeechTranscriber streaming backend is default and emits live partial transcripts.
- MLX Parakeet v2 sidecar remains fallback through `uv run --python 3.12 --script`.
- Local paths: Apple streams buffers → partials/final; MLX records WAV → sidecar transcribes → paste.
- Clipboard paste leaves transcript copied for manual fallback.
- Recent transcript shown with Copy button.
- Independent toggles:
  - end recording on silence
  - press Enter after pasting
  - ambient mode
- Configurable silence threshold and silence duration; defaults are -50 dBFS and 2.0s.
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

## Apple on-device streaming backend

Goal: make streaming dictation work. Apple SpeechTranscriber produces live partial transcript updates during recording; Sokki still pastes final text only by default. MLX Parakeet v2 remains batch fallback and accuracy baseline.

Implemented success criteria:

1. Live partial transcript appears in overlay/settings while Apple backend records.
2. `SokkiSmoke apple-stream-file` records partials before final transcript.
3. Smoke prints first-partial and finalization latency.
4. `SokkiSmoke end-to-end-textedit` verifies Apple streaming final text reaches TextEdit via paste.
5. No cloud fallback; Apple path uses SpeechTranscriber assets via `AssetInventory`.

## Backend strategy

Add backend enum:

```swift
enum ASRBackend {
    case mlxParakeetV2
    case appleSpeechTranscriber
}
```

Keep MLX Parakeet as known-good final/batch fallback. Apple SpeechTranscriber is default for streaming.

Implement Apple backend with the newer SpeechAnalyzer/SpeechTranscriber APIs first:

- Use Apple Speech framework's `SpeechAnalyzer` / `SpeechTranscriber` API when available in the local SDK.
- Configure English locale (`en_US`) and on-device assets only.
- Install/download required Apple on-device speech assets if API exposes that flow; surface clear status in UI.
- Consume audio buffers directly from `AudioCapture` rather than writing files.
- Emit partial/final transcript events for overlay/settings.
- Do not fall back to cloud recognition.

Fallback only if SpeechTranscriber is unavailable in the installed SDK/runtime:

- `SFSpeechRecognizer(locale: Locale(identifier: "en_US"))`
- `SFSpeechAudioBufferRecognitionRequest`
- `request.requiresOnDeviceRecognition = true`
- fail clearly if `supportsOnDeviceRecognition == false`
- no cloud fallback

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
- `AppleSpeechTranscriberBackend`: primary on-device Apple streaming path using SpeechAnalyzer/SpeechTranscriber.
- `AppleSFSpeechBackend`: fallback on-device streaming path only if SpeechTranscriber unavailable.

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

### Slice C — Apple SpeechTranscriber streaming backend

- Implement `AppleSpeechTranscriberBackend` using SpeechAnalyzer/SpeechTranscriber.
- Force local/on-device assets/recognition only.
- Surface unsupported/missing model/permission status clearly.
- Implement `SokkiSmoke apple-stream-file`.
- Add `AppleSFSpeechBackend` fallback only if SpeechTranscriber cannot compile/run on this SDK/runtime.

Verify:

```bash
swift run SokkiSmoke apple-stream-file /tmp/sokki-streaming-smoke.wav
```

Pass criteria:

- at least one partial transcript before final while file chunks are still being fed
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

SpeechTranscriber/SpeechAnalyzer may require newer SDK/runtime APIs or downloadable on-device assets. If unavailable, try SFSpeech on-device fallback; if that also fails, fail clearly and keep MLX default.

### Apple Speech permission friction

Speech recognition may require an additional permission beyond mic/input monitoring. Settings should show actionable status and buttons where possible.

### Partial transcript instability

Partial text can revise itself. Do not type partials into target apps initially. Show partials only in overlay/settings; paste final only.

### Streaming accuracy vs Parakeet

Apple may be faster but less accurate for code-ish prose. Keep backend picker and benchmark output.

### Test realism

`say` synthetic audio is not the same as live mic. It is still good enough for repeatable backend/insertion smoke. Final live dogfood comes after automated smoke.

## Compact handoff prompt

Continue Sokki from `PLAN.md`. Current app works with MLX Parakeet v2 batch dictation. Next milestone: add Apple on-device streaming backend without regressing MLX. Use the new SpeechAnalyzer/SpeechTranscriber APIs first, with SFSpeechRecognizer on-device fallback only if the new APIs are unavailable. First extract backend protocol and add `SokkiSmoke` target. Implement deterministic e2e tests with generated `say` WAV: `mlx-file`, `apple-stream-file`, and `end-to-end-textedit`. Apple backend must use local/on-device recognition/assets only and surface unsupported status instead of falling back to cloud. Show partial transcripts in overlay/settings, paste final only. After automated smoke passes, build/install `/Applications/Sokki.app` for manual dogfood.
