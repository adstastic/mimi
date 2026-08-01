@preconcurrency import AVFoundation
import AppKit
import XCTest
import MimiSpeech
@testable import Mimi

@MainActor
final class AmbientCrashRegressionTests: XCTestCase {
    func testAmbientMissingInputStopsInsteadOfRestartingMic() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        let config = ambientConfig(inputDeviceID: nil)

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            overlay: overlay,
            status: status,
            missingInputTimeout: 0.05
        )

        controller.updateAmbientMode()
        let stopped = await waitUntil({ audio.stopCount == 1 }, timeout: 1.0)
        XCTAssertTrue(stopped)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(audio.startInputDeviceIDs, [nil])
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertTrue(status.values.contains("No audio from microphone — choose another input"))
        XCTAssertTrue(overlay.messages.contains { $0.message == "No mic audio" })
    }

    func testAmbientStartFailureClearsTaskForRetry() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        let config = ambientConfig(inputDeviceID: "flaky-mic")
        audio.startError = AudioCapture.CaptureError.inputDeviceUnavailable

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.updateAmbientMode()
        let failed = await waitUntil({ status.values.contains("Mic error: Selected microphone is not available.") }, timeout: 1.0)
        XCTAssertTrue(failed)
        XCTAssertEqual(audio.stopCount, 1)

        audio.startError = nil
        controller.updateAmbientMode()
        let retried = await waitUntil({ audio.startInputDeviceIDs == ["flaky-mic", "flaky-mic"] }, timeout: 1.0)
        XCTAssertTrue(retried)
    }

    func testShortcutRecordingPausesAmbientSpeechBeforeStartingMic() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var config = ambientConfig(inputDeviceID: "shared-mic")
        asr.holdCancels()

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.updateAmbientMode()
        let ambientStarted = await waitUntil({
            audio.startInputDeviceIDs == ["shared-mic"] && asr.snapshotEvents().contains("stream.start")
        }, timeout: 1.0)
        XCTAssertTrue(ambientStarted)

        controller.hotkeyDown()
        let ambientCancelStarted = await waitUntil({
            asr.snapshotEvents().contains("stream.cancel.begin")
        }, timeout: 1.0)
        XCTAssertTrue(ambientCancelStarted)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(audio.startInputDeviceIDs, ["shared-mic"])

        asr.releaseCancels()
        let shortcutStarted = await waitUntil({
            audio.startInputDeviceIDs == ["shared-mic", "shared-mic"]
        }, timeout: 1.0)
        XCTAssertTrue(shortcutStarted)

        config = ambientConfig(inputDeviceID: "new-mic")
        controller.updateAmbientMode()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(audio.startInputDeviceIDs, ["shared-mic", "shared-mic"])

        controller.cancelRecording()
        let ambientResumedOnNewInput = await waitUntil({
            audio.startInputDeviceIDs == ["shared-mic", "shared-mic", "new-mic"]
        }, timeout: 1.0)
        XCTAssertTrue(ambientResumedOnNewInput)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(audio.startInputDeviceIDs, ["shared-mic", "shared-mic", "new-mic"])
    }

    func testShortcutStreamStartFailureRestartsAmbientMonitoring() async {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var config = ambientConfig(inputDeviceID: "shared-mic")
        config.silenceDetectionMode = .speechActivity
        config.voiceprintEnabled = false

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.updateAmbientMode()
        let ambientStarted = await waitUntil({
            audio.startInputDeviceIDs == ["shared-mic"]
                && asr.snapshotEvents().filter { $0 == "stream.start" }.count == 1
        }, timeout: 1.0)
        XCTAssertTrue(ambientStarted)

        asr.failNextStart(NSError(
            domain: "FakeSpeechAnalyzer",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Request was rejected"]
        ))
        controller.hotkeyDown()

        let ambientRestarted = await waitUntil({
            audio.startInputDeviceIDs == ["shared-mic", "shared-mic", "shared-mic"]
                && asr.snapshotEvents().filter { $0 == "stream.start" }.count == 2
        }, timeout: 1.0)
        XCTAssertTrue(ambientRestarted)
        XCTAssertEqual(audio.stopCount, 1)
    }

    func testReplacementRecordingWaitsForCanceledStreamCleanup() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var config = MimiConfig.defaults
        config.silenceDetectionMode = .speechActivity
        config.voiceprintEnabled = false

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.hotkeyDown()
        let firstStarted = await waitUntil({
            audio.startInputDeviceIDs.count == 1
                && asr.snapshotEvents().filter { $0 == "stream.start" }.count == 1
        }, timeout: 1.0)
        XCTAssertTrue(firstStarted)

        asr.holdCancels()
        controller.cancelRecording()
        let cancelStarted = await waitUntil({
            asr.snapshotEvents().contains("stream.cancel.begin")
        }, timeout: 1.0)
        XCTAssertTrue(cancelStarted)

        controller.hotkeyDown()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(audio.startInputDeviceIDs.count, 1)
        XCTAssertEqual(asr.snapshotEvents().filter { $0 == "stream.start" }.count, 1)

        asr.releaseCancels()
        let replacementStarted = await waitUntil({
            audio.startInputDeviceIDs.count == 2
                && asr.snapshotEvents().filter { $0 == "stream.start" }.count == 2
        }, timeout: 1.0)
        XCTAssertTrue(replacementStarted)
        let events = asr.snapshotEvents()
        XCTAssertLessThan(
            try XCTUnwrap(events.firstIndex(of: "stream.cancel.end")),
            try XCTUnwrap(events.lastIndex(of: "stream.start"))
        )
        controller.cancelRecording()
    }

    func testReplacementRecordingIgnoresStaleStreamEvents() async {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var partials: [String?] = []
        var config = MimiConfig.defaults
        config.silenceDetectionMode = .speechActivity
        config.voiceprintEnabled = false

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            overlay: overlay,
            status: status,
            partialTranscript: { partials.append($0) },
            missingInputTimeout: 10
        )

        controller.hotkeyDown()
        let firstStarted = await waitUntil({
            asr.snapshotEvents().filter { $0 == "stream.start" }.count == 1
        }, timeout: 1.0)
        XCTAssertTrue(firstStarted)

        controller.cancelRecording()
        controller.hotkeyDown()
        let replacementStarted = await waitUntil({
            asr.snapshotEvents().filter { $0 == "stream.start" }.count == 2
        }, timeout: 1.0)
        XCTAssertTrue(replacementStarted)

        asr.emitPartial("stale", streamIndex: 0)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(partials.compactMap { $0 }.contains("stale"))

        asr.emitPartial("current", streamIndex: 1)
        let currentDisplayed = await waitUntil({
            partials.compactMap { $0 }.contains("current")
        }, timeout: 1.0)
        XCTAssertTrue(currentDisplayed)
        controller.cancelRecording()
    }

    func testCanceledMicStartCannotOverwriteReplacementRecording() async {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var config = MimiConfig.defaults
        config.silenceAutoStopEnabled = false
        config.voiceprintEnabled = false
        audio.holdFirstStart = true

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.hotkeyDown()
        let firstStartPending = await waitUntil({ audio.firstStartPending }, timeout: 1.0)
        XCTAssertTrue(firstStartPending)

        controller.cancelRecording()
        controller.hotkeyDown()
        let replacementStarted = await waitUntil({
            audio.startInputDeviceIDs.count == 2 && status.values.last == "Recording…"
        }, timeout: 1.0)
        XCTAssertTrue(replacementStarted)

        audio.releaseFirstStart()
        let canceledStartFinished = await waitUntil({ audio.firstStartFinished }, timeout: 1.0)
        XCTAssertTrue(canceledStartFinished)
        XCTAssertEqual(status.values.last, "Recording…")
        controller.cancelRecording()
    }

    func testAmbientUpdateRejectsAlreadyQueuedOldEvent() async {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var config = ambientConfig(inputDeviceID: "old-mic")
        audio.peakDBFS = -20

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.updateAmbientMode()
        let firstStarted = await waitUntil({
            asr.snapshotEvents().filter { $0 == "stream.start" }.count == 1
        }, timeout: 1.0)
        XCTAssertTrue(firstStarted)

        asr.emitPartial("queued before update", streamIndex: 0)
        config = ambientConfig(inputDeviceID: "new-mic")
        controller.updateAmbientMode()

        let replacementStarted = await waitUntil({
            audio.startInputDeviceIDs == ["old-mic", "new-mic"]
                && asr.snapshotEvents().filter { $0 == "stream.start" }.count == 2
        }, timeout: 1.0)
        XCTAssertTrue(replacementStarted)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(audio.startInputDeviceIDs, ["old-mic", "new-mic"])
    }

    func testReplacedAmbientStreamIgnoresStaleEvents() async {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var config = ambientConfig(inputDeviceID: "old-mic")
        audio.peakDBFS = -20

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.updateAmbientMode()
        let firstStarted = await waitUntil({
            asr.snapshotEvents().filter { $0 == "stream.start" }.count == 1
        }, timeout: 1.0)
        XCTAssertTrue(firstStarted)

        config = ambientConfig(inputDeviceID: "new-mic")
        controller.updateAmbientMode()
        let replacementStarted = await waitUntil({
            audio.startInputDeviceIDs == ["old-mic", "new-mic"]
                && asr.snapshotEvents().filter { $0 == "stream.start" }.count == 2
        }, timeout: 1.0)
        XCTAssertTrue(replacementStarted)

        asr.emitPartial("stale", streamIndex: 0)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(audio.startInputDeviceIDs, ["old-mic", "new-mic"])

        asr.emitPartial("current", streamIndex: 1)
        let currentStartedRecording = await waitUntil({
            audio.startInputDeviceIDs == ["old-mic", "new-mic", "new-mic"]
        }, timeout: 1.0)
        XCTAssertTrue(currentStartedRecording)
        controller.cancelRecording()
    }

    func testAmbientInputChangeDuringRecordingRestartsOnceAfterRecording() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let inserter = FakeTextInserter()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var config = ambientConfig(inputDeviceID: "old-mic")
        audio.peakDBFS = -20
        asr.streamFinalText = "changed input"

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            textInserter: inserter,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.updateAmbientMode()
        let ambientStarted = await waitUntil({
            audio.startInputDeviceIDs == ["old-mic"] && asr.snapshotEvents().contains("stream.start")
        }, timeout: 1.0)
        XCTAssertTrue(ambientStarted)

        asr.emitPartial("start recording")
        let recordingStarted = await waitUntil({
            audio.startInputDeviceIDs == ["old-mic", "old-mic"]
        }, timeout: 1.0)
        XCTAssertTrue(recordingStarted)

        config = ambientConfig(inputDeviceID: "new-mic")
        controller.updateAmbientMode()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(audio.startInputDeviceIDs, ["old-mic", "old-mic"])

        controller.hotkeyDown()
        let restarted = await waitUntil({
            audio.startInputDeviceIDs == ["old-mic", "old-mic", "new-mic"]
        }, timeout: 1.0)
        XCTAssertTrue(restarted)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(audio.startInputDeviceIDs, ["old-mic", "old-mic", "new-mic"])
    }

    func testAmbientPassesConfiguredKeystrokesToPasteBoundary() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let inserter = FakeTextInserter()
        let overlay = FakeOverlay()
        let status = StatusSink()
        let prePasteKeystroke = MimiShortcut(keyCode: 48, modifierFlagsRaw: NSEvent.ModifierFlags.control.rawValue)
        let postPasteKeystroke = MimiShortcut(keyCode: 36, modifierFlagsRaw: NSEvent.ModifierFlags.command.rawValue)
        var config = ambientConfig(inputDeviceID: nil)
        config.ambientPasteSettings = PasteSettings(
            prePasteKeystroke: prePasteKeystroke,
            postPasteKeystroke: postPasteKeystroke,
            prePasteDelayMilliseconds: 325,
            postPasteDelayMilliseconds: 475
        )
        audio.peakDBFS = -20
        asr.streamFinalText = "review comment"

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            textInserter: inserter,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.updateAmbientMode()
        let streamStarted = await waitUntil({ asr.snapshotEvents().contains("stream.start") }, timeout: 1.0)
        XCTAssertTrue(streamStarted)

        asr.emitPartial("start comment")
        let recordingStarted = await waitUntil({ audio.startInputDeviceIDs.count == 2 }, timeout: 1.0)
        XCTAssertTrue(recordingStarted)
        XCTAssertTrue(inserter.insertedTexts.isEmpty)

        controller.hotkeyDown()
        let pasted = await waitUntil({ inserter.insertedTexts == ["review comment"] }, timeout: 1.0)
        XCTAssertTrue(pasted)
        XCTAssertEqual(inserter.prePasteKeystrokes, [prePasteKeystroke])
        XCTAssertEqual(inserter.postPasteKeystrokes, [postPasteKeystroke])
        XCTAssertEqual(inserter.prePasteDelays, [325])
        XCTAssertEqual(inserter.postPasteDelays, [475])
    }

    func testShortcutPassesConfiguredKeystrokesToPasteBoundary() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let inserter = FakeTextInserter()
        let overlay = FakeOverlay()
        let status = StatusSink()
        let prePasteKeystroke = MimiShortcut(keyCode: 48, modifierFlagsRaw: NSEvent.ModifierFlags.control.rawValue)
        let postPasteKeystroke = MimiShortcut(keyCode: 36, modifierFlagsRaw: NSEvent.ModifierFlags.command.rawValue)
        var config = MimiConfig.defaults
        config.preferredBackend = .appleSpeechTranscriber
        config.silenceDetectionMode = .speechActivity
        config.silenceAutoStopEnabled = false
        config.voiceprintEnabled = false
        config.dictationPasteSettings = PasteSettings(
            prePasteKeystroke: prePasteKeystroke,
            postPasteKeystroke: postPasteKeystroke,
            prePasteDelayMilliseconds: 225,
            postPasteDelayMilliseconds: 375
        )
        config.ambientPasteSettings = .defaults
        asr.streamFinalText = "shortcut comment"

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            textInserter: inserter,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.hotkeyDown()
        let streamStarted = await waitUntil({ asr.snapshotEvents().contains("stream.start") }, timeout: 1.0)
        XCTAssertTrue(streamStarted)
        try await Task.sleep(nanoseconds: 250_000_000)
        controller.hotkeyUp()
        let pasted = await waitUntil({ inserter.insertedTexts == ["shortcut comment"] }, timeout: 1.0)

        XCTAssertTrue(pasted)
        XCTAssertEqual(inserter.prePasteKeystrokes, [prePasteKeystroke])
        XCTAssertEqual(inserter.postPasteKeystrokes, [postPasteKeystroke])
        XCTAssertEqual(inserter.prePasteDelays, [225])
        XCTAssertEqual(inserter.postPasteDelays, [375])
    }

    func testAmbientStartsWhenTranscriptArrivesAfterLevelFallsBelowNoiseFloor() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var config = ambientConfig(inputDeviceID: "quiet-mic")
        config.silenceThresholdDBFS = -35
        audio.dbfs = -60
        audio.peakDBFS = -60

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.updateAmbientMode()
        let streamStarted = await waitUntil({ asr.snapshotEvents().contains("stream.start") }, timeout: 1.0)
        XCTAssertTrue(streamStarted)

        asr.emitPartial("quiet words")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(audio.startInputDeviceIDs, ["quiet-mic"])

        audio.peakDBFS = -20
        asr.emitPartial("delayed words")
        let speechStarted = await waitUntil({ audio.startInputDeviceIDs == ["quiet-mic", "quiet-mic"] }, timeout: 1.0)
        XCTAssertTrue(speechStarted)
    }

    func testLiveTranscriptUsesSameFillerCleanupAsFinalText() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var partials: [String?] = []
        var config = MimiConfig.defaults
        config.preferredBackend = .appleSpeechTranscriber
        config.silenceDetectionMode = .speechActivity
        config.silenceAutoStopEnabled = false
        config.voiceprintEnabled = false

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            overlay: overlay,
            status: status,
            partialTranscript: { partials.append($0) },
            missingInputTimeout: 10
        )

        controller.hotkeyDown()
        let streamStarted = await waitUntil({ asr.snapshotEvents().contains("stream.start") }, timeout: 1.0)
        XCTAssertTrue(streamStarted)
        asr.emitPartial("I, um, think so.")
        let cleanedPartialShown = await waitUntil({ partials.contains("I think so.") }, timeout: 1.0)

        XCTAssertTrue(cleanedPartialShown)
        XCTAssertFalse(partials.contains("I, um, think so."))

        asr.emitPartial("Um.")
        let stalePreviewCleared = await waitUntil({ partials.last.map { $0 == nil } ?? false }, timeout: 1.0)
        XCTAssertTrue(stalePreviewCleared)
        controller.cancelRecording()
    }

    func testFinalPasteCleansFillerAddedAfterLivePreview() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let inserter = FakeTextInserter()
        let history = HistoryStore()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var partials: [String?] = []
        var config = MimiConfig.defaults
        config.preferredBackend = .appleSpeechTranscriber
        config.silenceDetectionMode = .speechActivity
        config.silenceAutoStopEnabled = false
        config.voiceprintEnabled = false
        config.dictationPasteSettings.postPasteKeystroke = nil
        asr.streamFinalText = "I think we should. Ah, ship it Friday."

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            textInserter: inserter,
            history: history,
            overlay: overlay,
            status: status,
            partialTranscript: { partials.append($0) },
            missingInputTimeout: 10
        )

        controller.hotkeyDown()
        let streamStarted = await waitUntil({ asr.snapshotEvents().contains("stream.start") }, timeout: 1.0)
        XCTAssertTrue(streamStarted)
        asr.emitPartial("I think we should. ship it Friday.")
        let previewShown = await waitUntil({ partials.contains("I think we should. ship it Friday.") }, timeout: 1.0)
        XCTAssertTrue(previewShown)
        try await Task.sleep(nanoseconds: 250_000_000)
        controller.hotkeyUp()
        let pasted = await waitUntil({ !inserter.insertedTexts.isEmpty }, timeout: 1.0)

        XCTAssertTrue(pasted)
        XCTAssertEqual(inserter.insertedTexts, ["I think we should. ship it Friday."])
        XCTAssertEqual(history.lastTranscript, "I think we should. ship it Friday.")
    }

    func testFillerCleanupCanBeDisabledForPreviewAndFinalPaste() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let inserter = FakeTextInserter()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var partials: [String?] = []
        var config = MimiConfig.defaults
        config.preferredBackend = .appleSpeechTranscriber
        config.silenceDetectionMode = .speechActivity
        config.silenceAutoStopEnabled = false
        config.voiceprintEnabled = false
        config.dictationPasteSettings.postPasteKeystroke = nil
        config.fillerCleanupEnabled = false
        asr.streamFinalText = "I think we should. Ah, ship it Friday."

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            textInserter: inserter,
            overlay: overlay,
            status: status,
            partialTranscript: { partials.append($0) },
            missingInputTimeout: 10
        )

        controller.hotkeyDown()
        let streamStarted = await waitUntil({ asr.snapshotEvents().contains("stream.start") }, timeout: 1.0)
        XCTAssertTrue(streamStarted)
        asr.emitPartial("I, um, think so.")
        let rawPreviewShown = await waitUntil({ partials.contains("I, um, think so.") }, timeout: 1.0)
        XCTAssertTrue(rawPreviewShown)
        try await Task.sleep(nanoseconds: 250_000_000)
        controller.hotkeyUp()
        let pasted = await waitUntil({ !inserter.insertedTexts.isEmpty }, timeout: 1.0)

        XCTAssertTrue(pasted)
        XCTAssertEqual(inserter.insertedTexts, ["I think we should. Ah, ship it Friday."])
    }

    func testLiveTranscriptToggleSuppressesRawPartials() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var partials: [String?] = []
        var config = MimiConfig.defaults
        config.preferredBackend = .appleSpeechTranscriber
        config.silenceDetectionMode = .speechActivity
        config.silenceAutoStopEnabled = false
        config.showLiveTranscript = false

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            overlay: overlay,
            status: status,
            partialTranscript: { partials.append($0) },
            missingInputTimeout: 10
        )

        controller.hotkeyDown()
        let streamStarted = await waitUntil({ asr.snapshotEvents().contains("stream.start") }, timeout: 1.0)
        XCTAssertTrue(streamStarted)
        asr.emitPartial("raw transcript from every speaker")
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(partials.contains("raw transcript from every speaker"))
        controller.cancelRecording()
    }

    func testVoiceprintDisabledTranscribesOriginalAudio() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var config = MimiConfig.defaults
        config.preferredBackend = .mlxParakeetV2
        config.silenceAutoStopEnabled = false
        config.voiceprintEnabled = false
        let voiceprint = FakeVoiceprintVerifier(extraction: VoiceprintExtraction(
            audioURL: nil,
            totalSegmentCount: 1,
            keptSegmentCount: 0,
            keptDurationSeconds: 0,
            bestDistance: 0.9,
            threshold: 0.3
        ))

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            voiceprint: voiceprint,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.hotkeyDown()
        let started = await waitUntil({ audio.startInputDeviceIDs == [nil] }, timeout: 1.0)
        XCTAssertTrue(started)
        try await Task.sleep(nanoseconds: 250_000_000)
        controller.hotkeyUp()

        let transcribedOriginalAudio = await waitUntil({
            asr.snapshotEvents().contains { $0.hasPrefix("transcribe.path=") }
        }, timeout: 1.0)
        XCTAssertTrue(transcribedOriginalAudio)
        XCTAssertEqual(voiceprint.extractionThresholds, [])
    }

    func testVoiceprintWithNoMatchingSegmentsSkipsTranscriptionAndPaste() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var config = MimiConfig.defaults
        config.preferredBackend = .mlxParakeetV2
        config.silenceAutoStopEnabled = false
        let voiceprint = FakeVoiceprintVerifier(extraction: VoiceprintExtraction(
            audioURL: nil,
            totalSegmentCount: 2,
            keptSegmentCount: 0,
            keptDurationSeconds: 0,
            bestDistance: 0.7,
            threshold: 0.3
        ))

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            voiceprint: voiceprint,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.hotkeyDown()
        let started = await waitUntil({ audio.startInputDeviceIDs == [nil] }, timeout: 1.0)
        XCTAssertTrue(started)
        try await Task.sleep(nanoseconds: 250_000_000)
        controller.hotkeyUp()

        let ignored = await waitUntil({ status.values.contains("Ignored — no matching speaker") }, timeout: 1.0)
        XCTAssertTrue(ignored)
        XCTAssertFalse(asr.snapshotEvents().contains("transcribe"))
        XCTAssertTrue(overlay.messages.contains { $0.message == "Ignored — no matching speaker" })
    }

    func testVoiceprintMatchingSegmentsTranscribesExtractedAudio() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var config = MimiConfig.defaults
        config.preferredBackend = .mlxParakeetV2
        config.silenceAutoStopEnabled = false
        config.voiceprintThreshold = 0.92
        let ownerURL = URL(fileURLWithPath: "/tmp/mimi-owner-filtered.wav")
        let voiceprint = FakeVoiceprintVerifier(extraction: VoiceprintExtraction(
            audioURL: ownerURL,
            totalSegmentCount: 3,
            keptSegmentCount: 1,
            keptDurationSeconds: 1.2,
            bestDistance: 0.2,
            threshold: 0.3
        ))

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            voiceprint: voiceprint,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.hotkeyDown()
        let started = await waitUntil({ audio.startInputDeviceIDs == [nil] }, timeout: 1.0)
        XCTAssertTrue(started)
        try await Task.sleep(nanoseconds: 250_000_000)
        controller.hotkeyUp()

        let transcribedFilteredAudio = await waitUntil({
            asr.snapshotEvents().contains("transcribe.path=\(ownerURL.path)")
        }, timeout: 1.0)
        XCTAssertTrue(transcribedFilteredAudio)
        XCTAssertTrue(status.values.contains("Transcribing your speech…"))
        XCTAssertEqual(voiceprint.extractionThresholds, [0.92])
    }

    func testAppleVoiceprintWithNoMatchingSegmentsCancelsStreamBeforeFinalizing() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var partials: [String?] = []
        var config = MimiConfig.defaults
        config.preferredBackend = .appleSpeechTranscriber
        config.silenceDetectionMode = .speechActivity
        config.silenceAutoStopEnabled = false
        let voiceprint = FakeVoiceprintVerifier(extraction: VoiceprintExtraction(
            audioURL: nil,
            totalSegmentCount: 2,
            keptSegmentCount: 0,
            keptDurationSeconds: 0,
            bestDistance: 0.7,
            threshold: 0.3
        ))

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            voiceprint: voiceprint,
            overlay: overlay,
            status: status,
            partialTranscript: { partials.append($0) },
            missingInputTimeout: 10
        )

        controller.hotkeyDown()
        let streamStarted = await waitUntil({ asr.snapshotEvents().contains("stream.start") }, timeout: 1.0)
        XCTAssertTrue(streamStarted)
        asr.emitPartial("not mine")
        let partialShown = await waitUntil({ partials.contains("not mine") }, timeout: 1.0)
        XCTAssertTrue(partialShown)
        try await Task.sleep(nanoseconds: 250_000_000)
        controller.hotkeyUp()

        let ignored = await waitUntil({ status.values.contains("Ignored — no matching speaker") }, timeout: 1.0)
        XCTAssertTrue(ignored)
        let events = asr.snapshotEvents()
        XCTAssertTrue(events.contains("stream.cancel.begin"))
        XCTAssertFalse(events.contains("stream.finish"))
        XCTAssertFalse(events.contains("transcribe.apple"))
        XCTAssertFalse(partials.isEmpty)
        XCTAssertNil(partials[partials.count - 1])
    }

    func testAmbientSpeechStreamFailureStopsMic() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        let config = ambientConfig(inputDeviceID: "bad-mic")
        asr.startError = NSError(domain: "FakeASR", code: 1, userInfo: [NSLocalizedDescriptionKey: "stream failed"])

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.updateAmbientMode()

        let stopped = await waitUntil({ audio.stopCount == 1 }, timeout: 1.0)
        XCTAssertTrue(stopped)
        XCTAssertTrue(status.values.contains("Apple Speech error: stream failed"))
    }

    func testAmbientMicChangeWaitsForSpeechCancelBeforeRestartingMic() async throws {
        let audio = FakeAudioCapture()
        let asr = FakeASRService()
        let overlay = FakeOverlay()
        let status = StatusSink()
        var config = ambientConfig(inputDeviceID: "old-mic")
        asr.holdCancels()

        let controller = makeController(
            configProvider: { config },
            audio: audio,
            asr: asr,
            overlay: overlay,
            status: status,
            missingInputTimeout: 10
        )

        controller.updateAmbientMode()
        let firstStart = await waitUntil({
            audio.startInputDeviceIDs == ["old-mic"] && asr.snapshotEvents().contains("stream.start")
        }, timeout: 1.0)
        XCTAssertTrue(firstStart)

        config = ambientConfig(inputDeviceID: "new-mic")
        controller.updateAmbientMode()
        let cancelStarted = await waitUntil({
            audio.stopCount == 1 && asr.snapshotEvents().contains("stream.cancel.begin")
        }, timeout: 1.0)
        XCTAssertTrue(cancelStarted)

        config = ambientConfig(inputDeviceID: "newer-mic")
        controller.updateAmbientMode()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(audio.startInputDeviceIDs, ["old-mic"])

        asr.releaseCancels()
        let restarted = await waitUntil({
            audio.startInputDeviceIDs == ["old-mic", "newer-mic"]
        }, timeout: 1.0)
        XCTAssertTrue(restarted)
    }

    private func ambientConfig(inputDeviceID: String?) -> MimiConfig {
        var config = MimiConfig.defaults
        config.preferredBackend = .appleSpeechTranscriber
        config.ambientModeEnabled = true
        config.inputDeviceID = inputDeviceID
        return config
    }

    private func makeController(
        configProvider: @escaping () -> MimiConfig,
        audio: AudioCapturing,
        asr: ASRServicing,
        voiceprint: VoiceprintVerifying? = nil,
        textInserter: TextInserting? = nil,
        history: HistoryStore? = nil,
        overlay: OverlayShowing,
        status: StatusSink,
        partialTranscript: ((String?) -> Void)? = nil,
        missingInputTimeout: TimeInterval
    ) -> DictationController {
        DictationController(
            configProvider: configProvider,
            audioCapture: audio,
            asrService: asr,
            voiceprintVerifier: voiceprint,
            textInserter: textInserter ?? TextInserter(),
            history: history ?? HistoryStore(),
            overlay: overlay,
            onStatus: { status.append($0) },
            onTranscript: { _ in },
            onPartialTranscript: { partialTranscript?($0) },
            missingInputTimeout: missingInputTimeout
        )
    }

    private func waitUntil(_ predicate: @MainActor @escaping () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }
}

@MainActor
private final class FakeAudioCapture: AudioCapturing {
    var startInputDeviceIDs: [String?] = []
    var stopCount = 0
    var monitorHandlerSetCount = 0
    var dbfs: Double = -120
    var peakDBFS: Double = -120
    var startError: Error?
    var holdFirstStart = false
    private(set) var firstStartFinished = false
    private var firstStartContinuation: CheckedContinuation<Void, Never>?

    var firstStartPending: Bool {
        firstStartContinuation != nil
    }

    func start(preRollMilliseconds: Int, inputDeviceID: String?) async throws {
        let isFirstStart = startInputDeviceIDs.isEmpty
        startInputDeviceIDs.append(inputDeviceID)
        defer {
            if isFirstStart { firstStartFinished = true }
        }
        if holdFirstStart, isFirstStart {
            await withCheckedContinuation { continuation in
                firstStartContinuation = continuation
            }
            try Task.checkCancellation()
        }
        if let startError { throw startError }
    }

    func releaseFirstStart() {
        firstStartContinuation?.resume()
        firstStartContinuation = nil
    }

    func setMonitorBufferHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        monitorHandlerSetCount += 1
    }

    func beginRecording(bufferHandler: ((AVAudioPCMBuffer) -> Void)?, replayPreRollToHandler: Bool) {}

    func finishRecording() throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
    }

    func cancelRecording() {}

    func stop() {
        stopCount += 1
    }

    func currentDBFS() -> Double {
        dbfs
    }

    func peakDBFS(within seconds: TimeInterval) -> Double {
        peakDBFS
    }

    func secondsSinceLastBuffer() -> TimeInterval? {
        nil
    }
}

private final class FakeASRService: ASRServicing {
    private let lock = NSLock()
    private var events: [String] = []
    private var eventHandlers: [AppleSpeechTranscriberBackend.EventHandler] = []
    private var cancelsHeld = false
    private var nextStartError: Error?
    var startError: Error?
    var streamFinalText = ""
    private var pendingCancel: CheckedContinuation<Void, Never>?

    func holdCancels() {
        lock.lock()
        cancelsHeld = true
        lock.unlock()
    }

    func failNextStart(_ error: Error) {
        lock.lock()
        nextStartError = error
        lock.unlock()
    }

    func releaseCancels() {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        cancelsHeld = false
        continuation = pendingCancel
        pendingCancel = nil
        lock.unlock()
        continuation?.resume()
    }

    func snapshotEvents() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func emitPartial(_ text: String, streamIndex: Int? = nil) {
        let handler: AppleSpeechTranscriberBackend.EventHandler?
        lock.lock()
        if let streamIndex, eventHandlers.indices.contains(streamIndex) {
            handler = eventHandlers[streamIndex]
        } else {
            handler = eventHandlers.last
        }
        lock.unlock()
        handler?(.partial(text))
    }

    func prepare(backend: ASRBackend) async throws {}

    func transcribeApple(audioURL: URL) async throws -> String {
        record("transcribe.apple")
        record("transcribe.apple.path=\(audioURL.path)")
        return ""
    }

    func startAppleStream(
        detectSpeech: Bool,
        onEvent: @escaping AppleSpeechTranscriberBackend.EventHandler,
        onDetection: AppleSpeechTranscriberBackend.DetectionHandler?
    ) async throws {
        let oneShotError = lock.withLock {
            let error = nextStartError
            nextStartError = nil
            return error
        }
        if let oneShotError { throw oneShotError }
        if let startError { throw startError }
        recordStart(onEvent)
    }

    func appendAppleBuffer(_ buffer: AVAudioPCMBuffer) async throws {}

    func finishAppleStream() async throws -> String {
        record("stream.finish")
        return streamFinalText
    }

    func cancelAppleStream() async {
        record("stream.cancel.begin")
        if shouldHoldCancel() {
            await withCheckedContinuation { continuation in
                var resumeNow = false
                lock.lock()
                if cancelsHeld {
                    pendingCancel = continuation
                } else {
                    resumeNow = true
                }
                lock.unlock()
                if resumeNow {
                    continuation.resume()
                }
            }
        }
        record("stream.cancel.end")
    }

    func transcribe(audioURL: URL) async throws -> String {
        record("transcribe")
        record("transcribe.path=\(audioURL.path)")
        return ""
    }

    private func recordStart(_ handler: @escaping AppleSpeechTranscriberBackend.EventHandler) {
        lock.lock()
        eventHandlers.append(handler)
        events.append("stream.start")
        lock.unlock()
    }

    private func shouldHoldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelsHeld
    }

    private func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}

private final class FakeVoiceprintVerifier: VoiceprintVerifying {
    private let verification: VoiceprintVerification?
    private let extraction: VoiceprintExtraction?
    private(set) var verificationThresholds: [Float?] = []
    private(set) var extractionThresholds: [Float?] = []

    init(verification: VoiceprintVerification? = nil, extraction: VoiceprintExtraction? = nil) {
        self.verification = verification
        self.extraction = extraction
    }

    func hasProfile() async -> Bool {
        verification != nil || extraction != nil
    }

    func verify(audioURL: URL, thresholdOverride: Float?) async throws -> VoiceprintVerification? {
        verificationThresholds.append(thresholdOverride)
        return verification
    }

    func extractOwnerSpeech(audioURL: URL, thresholdOverride: Float?) async throws -> VoiceprintExtraction? {
        extractionThresholds.append(thresholdOverride)
        return extraction
    }
}

@MainActor
private final class FakeTextInserter: TextInserting {
    var insertedTexts: [String] = []
    var prePasteKeystrokes: [MimiShortcut?] = []
    var postPasteKeystrokes: [MimiShortcut?] = []
    var prePasteDelays: [Int] = []
    var postPasteDelays: [Int] = []

    func insert(
        _ text: String,
        prePasteKeystroke: MimiShortcut?,
        prePasteDelayMilliseconds: Int,
        postPasteKeystroke: MimiShortcut?,
        postPasteDelayMilliseconds: Int
    ) async throws {
        insertedTexts.append(text)
        prePasteKeystrokes.append(prePasteKeystroke)
        postPasteKeystrokes.append(postPasteKeystroke)
        prePasteDelays.append(prePasteDelayMilliseconds)
        postPasteDelays.append(postPasteDelayMilliseconds)
    }

    func copyToClipboard(_ text: String) throws {}
}

@MainActor
private final class FakeOverlay: OverlayShowing {
    var messages: [(message: String, detail: String?, level: Double?)] = []
    var hiddenAfter: [Int] = []

    func show(_ message: String, detail: String?, level: Double?) {
        messages.append((message, detail, level))
    }

    func updateLevel(_ level: Double) {}

    func updateDetail(_ detail: String?) {}

    func hide(after milliseconds: Int) {
        hiddenAfter.append(milliseconds)
    }
}

@MainActor
private final class StatusSink {
    var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}
