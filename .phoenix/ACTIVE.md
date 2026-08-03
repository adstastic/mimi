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
Current phase: review fixes applied; verifying
Completed evidence:
- 2026-08-03 live log: CoreAudio ID 132→358; fresh engine startup consumed 368 ms of a 411 ms hold; only ~32 ms audio preceded SFSpeechErrorDomain code 1 RecogRejected; retry reused warm engine and worked.
- User approved brief microphone/privacy-indicator activation after launch and wake.
- User requested “Mimi ready” in existing recording overlay after successful prime.
- RED: `swift test --filter AmbientCrashRegressionTests.testPreparingAudioWaitsForInputAndShowsReady` failed because no audio start, stop, or ready overlay occurred.
- RED: `swift test --filter SystemWakeMonitorTests.testWorkspaceWakeNotificationCallsHandler` timed out because wake was not observed.
- GREEN: both focused tests pass. Controller primes through first input buffer, stops capture, and shows “Mimi ready”; AppModel primes before hotkeys on launch and observes NSWorkspace wake for another bounded prime.
- CHECKS: `swift test` passed 71 tests; `swift test --sanitize=thread` passed 71 tests; `git diff --check` passed.
- REVIEW: all reviewers found prime ownership races: stale prime can stop newer dictation/voiceprint/ambient capture; wake hotkey stop/restart can lose held-key state or override shortcut recording; launch permission prompt is not bounded. Structure reviewer recommends moving first-buffer readiness into AudioCapture and keeping lifecycle ownership centralized.
- TEST ISOLATION INCIDENT: test helper defaulted to production TextInserter; cold-start bounded test could paste `bounded` into user focus during full suites. Replaced fallback with FakeTextInserter and confirmed no production TextInserter construction remains under Tests. User approved resuming isolated tests only.
- REVIEW FIXES: controller now reserves `.preparingAudio` ownership; hotkeys remain installed; voiceprint cannot begin during prime; launch no longer awaits permission/prime; native Combine wake subscription replaces thin wrapper; ambient wake requests reconciliation. Focused ownership, timeout, and ready-overlay tests pass.
Current hypothesis: Priming the fresh route through its first buffer before user input removes wake-only startup latency and rejection.
Next action: Run isolated full suite/TSan, inspect final diff, rerun affected review axes, then signed manual-QA build with explicit user boundary.
Owned files: .phoenix/ACTIVE.md, Sources/Mimi/AppModel.swift, Sources/Mimi/DictationController.swift, Sources/Mimi/SystemWakeMonitor.swift, Tests/MimiTests/AmbientCrashRegressionTests.swift, Tests/MimiTests/SystemWakeMonitorTests.swift.
Pre-existing work to preserve: none; initial staged diff hash e69de29bb2d1d6434b8b29ae775ad8c2e48c5391.
Review findings / decisions pending: exact smallest injectable seam for AppModel wake observation and audio priming.
