# Active Dev Loop
Task: Prevent first post-wake dictation rejection
Goal: Prime the selected microphone after app launch and system wake so first dictation receives real audio immediately.
Success criteria:
- Launch and NSWorkspace wake both trigger one bounded microphone prime.
- Prime waits for an input buffer, stops capture, and never starts transcription or recording.
- Successful prime shows “Mimi ready” in the existing recording overlay and then hides.
- First post-wake dictation no longer reaches Apple Speech with only one tiny buffer.
- Focused tests, full suite, Thread Sanitizer, signed install, and human QA pass.
Must remain true / non-goals:
- No continuously armed microphone.
- No config-system or broader review-finding work in this slice.
- Existing dictation, ambient mode, route switching, and cancellation behavior remain unchanged.
Current phase: calibrated; creating red Oracle
Completed evidence:
- 2026-08-03 live log: CoreAudio ID 132→358; fresh engine startup consumed 368 ms of a 411 ms hold; only ~32 ms audio preceded SFSpeechErrorDomain code 1 RecogRejected; retry reused warm engine and worked.
- User approved brief microphone/privacy-indicator activation after launch and wake.
- User requested “Mimi ready” in existing recording overlay after successful prime.
Current hypothesis: Priming the fresh route through its first buffer before user input removes wake-only startup latency and rejection.
Next action: Add behavior-focused failing tests for launch/wake prime and ready overlay.
Owned files: .phoenix/ACTIVE.md; expected AppModel/AudioCapture seams and focused tests.
Pre-existing work to preserve: none; initial staged diff hash e69de29bb2d1d6434b8b29ae775ad8c2e48c5391.
Review findings / decisions pending: exact smallest injectable seam for AppModel wake observation and audio priming.
