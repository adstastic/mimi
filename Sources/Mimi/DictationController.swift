@preconcurrency import AVFoundation
import Foundation
import MimiSpeech

protocol AudioCapturing: AnyObject {
    @MainActor func start(preRollMilliseconds: Int, inputDeviceID: String?) async throws
    @MainActor func setMonitorBufferHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?)
    @MainActor func beginRecording(bufferHandler: ((AVAudioPCMBuffer) -> Void)?, replayPreRollToHandler: Bool)
    @MainActor func finishRecording() throws -> URL
    @MainActor func cancelRecording()
    @MainActor func stop()
    @MainActor func currentDBFS() -> Double
    @MainActor func peakDBFS(within seconds: TimeInterval) -> Double
    @MainActor func secondsSinceLastBuffer() -> TimeInterval?
}

protocol ASRServicing: AnyObject {
    func prepare(backend: ASRBackend) async throws
    func transcribeApple(audioURL: URL) async throws -> String
    func startAppleStream(
        detectSpeech: Bool,
        onEvent: @escaping AppleSpeechTranscriberBackend.EventHandler,
        onDetection: AppleSpeechTranscriberBackend.DetectionHandler?
    ) async throws
    func appendAppleBuffer(_ buffer: AVAudioPCMBuffer) async throws
    func finishAppleStream() async throws -> String
    func cancelAppleStream() async
    func transcribe(audioURL: URL) async throws -> String
}

@MainActor
protocol TextInserting: AnyObject {
    func insert(
        _ text: String,
        prePasteKeystroke: MimiShortcut?,
        prePasteDelayMilliseconds: Int,
        postPasteKeystroke: MimiShortcut?,
        postPasteDelayMilliseconds: Int
    ) async throws
    func copyToClipboard(_ text: String) throws
}

protocol VoiceprintVerifying: AnyObject {
    func hasProfile() async -> Bool
    func verify(audioURL: URL, thresholdOverride: Float?) async throws -> VoiceprintVerification?
    func extractOwnerSpeech(audioURL: URL, thresholdOverride: Float?) async throws -> VoiceprintExtraction?
}

actor FileVoiceprintVerifier: VoiceprintVerifying {
    private let service: VoiceprintEmbeddingService

    init(service: VoiceprintEmbeddingService = VoiceprintEmbeddingService()) {
        self.service = service
    }

    func hasProfile() async -> Bool {
        FileManager.default.fileExists(atPath: VoiceprintPrototype.defaultProfileURL.path)
    }

    func verify(audioURL: URL, thresholdOverride: Float?) async throws -> VoiceprintVerification? {
        do {
            let profile = try VoiceprintPrototype.loadProfile()
            return try await service.verify(audioURL: audioURL, against: profile, thresholdOverride: thresholdOverride)
        } catch VoiceprintPrototype.VoiceprintError.profileMissing(_) {
            return nil
        }
    }

    func extractOwnerSpeech(audioURL: URL, thresholdOverride: Float?) async throws -> VoiceprintExtraction? {
        do {
            let profile = try VoiceprintPrototype.loadProfile()
            return try await service.extractOwnerSpeech(audioURL: audioURL, profile: profile, thresholdOverride: thresholdOverride)
        } catch VoiceprintPrototype.VoiceprintError.profileMissing(_) {
            return nil
        }
    }
}

@MainActor
protocol OverlayShowing: AnyObject {
    func show(_ message: String, detail: String?, level: Double?)
    func updateLevel(_ level: Double)
    func updateDetail(_ detail: String?)
    func hide(after milliseconds: Int)
}

extension OverlayShowing {
    func show(_ message: String) {
        show(message, detail: nil, level: nil)
    }

    func show(_ message: String, detail: String?) {
        show(message, detail: detail, level: nil)
    }
}

extension AudioCapture: AudioCapturing {}
extension ASRService: ASRServicing {}
extension TextInserter: TextInserting {}
extension OverlayWindowController: OverlayShowing {}

@MainActor
final class DictationController {
    private enum RecordingMode {
        case pressing(startedAt: Date)
        case toggle
        case ambient
    }

    private struct RecordingPlan {
        let config: MimiConfig
        let isAmbient: Bool
        let usesAppleStream: Bool
        let usesSpeechActivityStop: Bool
        let pasteSettings: PasteSettings
        let ambientUpdateGeneration: Int

        init(config: MimiConfig, isAmbient: Bool, ambientUpdateGeneration: Int) {
            let normalizedConfig = config.normalizedForBackend()
            let capabilities = normalizedConfig.preferredBackend.capabilities
            self.config = normalizedConfig
            self.isAmbient = isAmbient
            usesAppleStream = capabilities.usesStreamingTranscription(
                isAmbient: isAmbient,
                silenceDetectionMode: normalizedConfig.silenceDetectionMode
            )
            usesSpeechActivityStop = capabilities.usesSpeechActivityStop(normalizedConfig.silenceDetectionMode)
            pasteSettings = isAmbient
                ? normalizedConfig.ambientPasteSettings
                : normalizedConfig.dictationPasteSettings
            self.ambientUpdateGeneration = ambientUpdateGeneration
        }
    }

    private enum State {
        case idle
        case preparingAudio
        case recording(RecordingMode, RecordingPlan)
        case processing
    }

    private struct TranscriptionAudio {
        let url: URL
        let useAppleStreamFinal: Bool
    }

    private enum StopReason: String {
        case released = "Released"
        case stopped = "Stopped"
        case silence = "Silence"
    }

    private let configProvider: () -> MimiConfig
    private let audioCapture: AudioCapturing
    private let asrService: ASRServicing
    private let voiceprintVerifier: VoiceprintVerifying?
    private let textInserter: TextInserting
    private let history: HistoryStore
    private let overlay: OverlayShowing
    private let onStatus: (String) -> Void
    private let onTranscript: (String?) -> Void
    private let onPartialTranscript: (String?) -> Void
    private let missingInputTimeout: TimeInterval

    private var state: State = .idle
    private var recordingGeneration = 0
    private var silenceTask: Task<Void, Never>?
    private var ambientTask: Task<Void, Never>?
    private var speechDetectedByDetector = false
    private var lastSpeechDetectedAt: Date?
    private var sawSpeech = false
    private var silenceBeganAt: Date?
    private var ambientCooldownUntil: Date?
    private var ambientMicStartedAt: Date?
    private var engineStartTask: Task<Void, Never>?
    private var appleStreamTask: Task<Void, Never>?
    private var appleStreamCleanupTask: Task<Void, Never>?
    private var appleStreamCleanupGeneration = 0
    private var ambientStreamGeneration = 0
    private var ambientReconcileTask: Task<Void, Never>?
    private var ambientReconcilePending = false
    private var ambientUpdateGeneration = 0
    private var lastAmbientDecisionLogAt = Date.distantPast
    private var meterOpen = false
    private var meterReleaseDeadline = Date.distantPast
    private var temporaryAudioURLs: Set<URL> = []

    private var isAmbientRecording: Bool {
        if case .recording(.ambient, _) = state { true } else { false }
    }

    init(
        configProvider: @escaping () -> MimiConfig,
        audioCapture: AudioCapturing,
        asrService: ASRServicing,
        voiceprintVerifier: VoiceprintVerifying? = nil,
        textInserter: TextInserting,
        history: HistoryStore,
        overlay: OverlayShowing,
        onStatus: @escaping (String) -> Void,
        onTranscript: @escaping (String?) -> Void,
        onPartialTranscript: @escaping (String?) -> Void,
        missingInputTimeout: TimeInterval = 2
    ) {
        self.configProvider = configProvider
        self.audioCapture = audioCapture
        self.asrService = asrService
        self.voiceprintVerifier = voiceprintVerifier
        self.textInserter = textInserter
        self.history = history
        self.overlay = overlay
        self.onStatus = onStatus
        self.onTranscript = onTranscript
        self.onPartialTranscript = onPartialTranscript
        self.missingInputTimeout = missingInputTimeout
    }

    func prepareAudio() async -> Bool {
        guard case .idle = state else { return false }
        let config = configProvider().normalizedForBackend()
        guard !config.ambientModeEnabled else { return false }
        let generation = recordingGeneration
        state = .preparingAudio
        defer {
            if case .preparingAudio = state {
                audioCapture.stop()
                state = .idle
            }
        }

        do {
            let startedAt = Date()
            try await audioCapture.start(
                preRollMilliseconds: config.preRollMilliseconds,
                inputDeviceID: config.inputDeviceID
            )
            let ready = await waitForFirstAudioBuffer(
                recordingGeneration: generation,
                receivedAfter: startedAt
            )
            guard ready, recordingGeneration == generation, case .preparingAudio = state else { return false }
            audioCapture.stop()
            state = .idle
            overlay.show("Mimi ready")
            overlay.hide(after: 900)
            return true
        } catch {
            let nsError = error as NSError
            DebugLog.write("audio preparation error domain=\(nsError.domain) code=\(nsError.code) detail=\(nsError.localizedDescription)")
            return false
        }
    }

    func prepareASR() {
        Task {
            do {
                let backend = configProvider().preferredBackend
                onStatus("Preparing \(backend.displayName)…")
                try await asrService.prepare(backend: backend)
                onStatus("Ready — hold Right Command to dictate")
            } catch {
                onStatus("ASR error: \(error.localizedDescription)")
                overlay.show(AppBrand.errorTitle, detail: error.localizedDescription)
            }
        }
    }

    func hotkeyDown() {
        DebugLog.write("dictation hotkey down")
        switch state {
        case .idle:
            startRecording(mode: .pressing(startedAt: Date()))
        case .recording(let mode, _):
            switch mode {
            case .toggle, .ambient:
                Task { await stopAndTranscribe(reason: .stopped) }
            case .pressing:
                break
            }
        case .preparingAudio:
            state = .idle
            startRecording(mode: .pressing(startedAt: Date()))
        case .processing:
            break
        }
    }

    func hotkeyUp() {
        guard case .recording(.pressing(let startedAt), let plan) = state else { return }

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        DebugLog.write("dictation hotkey up elapsedMs=\(elapsedMs)")
        if elapsedMs < plan.config.tapThresholdMilliseconds {
            state = .recording(.toggle, plan)
            onStatus("Recording — tap Right Command again to stop")
            overlay.show(
                "Recording",
                detail: "Tap Right Command again or pause",
                level: meterLevel(audioCapture.currentDBFS(), threshold: plan.config.silenceThresholdDBFS)
            )
        } else {
            Task { await stopAndTranscribe(reason: .released) }
        }
    }

    func updateAmbientMode() {
        ambientUpdateGeneration &+= 1
        ambientReconcilePending = true
        guard ambientReconcileTask == nil else { return }
        ambientReconcileTask = Task { [weak self] in
            await self?.drainAmbientReconcileRequests()
        }
    }

    func copyLastTranscript() {
        guard let transcript = history.lastTranscript else { return }
        do {
            try textInserter.copyToClipboard(transcript)
            overlay.show("Copied last transcript", detail: preview(transcript))
            overlay.hide(after: 900)
        } catch {
            overlay.show("Copy error", detail: error.localizedDescription)
        }
    }

    @discardableResult
    func correctLastTranscript(id: UUID, text: String) -> Bool {
        guard let corrected = history.updateLastTranscript(id: id, text: text) else {
            onStatus("Last dictation changed — correction not saved")
            overlay.show("Last dictation changed", detail: "Open Correct again")
            overlay.hide(after: 1_200)
            return false
        }
        onTranscript(corrected)
        do {
            try textInserter.copyToClipboard(corrected)
            onStatus("Correction saved + copied")
            overlay.show("Correction saved + copied", detail: preview(corrected))
            overlay.hide(after: 1_200)
        } catch {
            onStatus("Correction saved; copy failed")
            overlay.show("Copy error", detail: error.localizedDescription)
        }
        return true
    }

    func shutdown() {
        recordingGeneration &+= 1
        ambientStreamGeneration &+= 1
        silenceTask?.cancel()
        engineStartTask?.cancel()
        appleStreamTask?.cancel()
        ambientTask?.cancel()
        ambientReconcileTask?.cancel()
        audioCapture.stop()
        cleanupTemporaryAudio()
        state = .idle
    }

    func cancelRecording() {
        guard case .recording(_, let plan) = state else { return }
        recordingGeneration &+= 1
        if plan.isAmbient { ambientStreamGeneration &+= 1 }
        let resumeAmbient = shouldRunAmbientMonitoring()
        silenceTask?.cancel()
        silenceTask = nil
        engineStartTask?.cancel()
        engineStartTask = nil
        if resumeAmbient {
            audioCapture.cancelRecording()
            audioCapture.setMonitorBufferHandler(nil)
            ambientCooldownUntil = Date().addingTimeInterval(1)
        } else {
            audioCapture.stop()
        }
        appleStreamTask?.cancel()
        appleStreamTask = nil
        onPartialTranscript(nil)
        state = .idle
        if plan.usesAppleStream || resumeAmbient {
            appleStreamCleanupGeneration &+= 1
            let cleanupGeneration = appleStreamCleanupGeneration
            let canceledRecordingGeneration = recordingGeneration
            let previousCleanupTask = appleStreamCleanupTask
            appleStreamCleanupTask = Task { @MainActor [weak self, asrService] in
                await previousCleanupTask?.value
                await asrService.cancelAppleStream()
                guard let self, self.appleStreamCleanupGeneration == cleanupGeneration else { return }
                self.appleStreamCleanupTask = nil
                guard resumeAmbient,
                      self.recordingGeneration == canceledRecordingGeneration,
                      case .idle = self.state else { return }
                self.resumeAmbientMonitoringAfterRecording(plan: plan)
            }
        }
        onStatus(resumeAmbient ? "Ambient armed" : "Cancelled")
        overlay.show("Cancelled")
        overlay.hide(after: 700)
    }

    private func startRecording(mode: RecordingMode, speechAlreadyDetected: Bool = false) {
        recordingGeneration &+= 1
        let generation = recordingGeneration
        let isAmbient = if case .ambient = mode { true } else { false }
        let plan = RecordingPlan(
            config: configProvider(),
            isAmbient: isAmbient,
            ambientUpdateGeneration: ambientUpdateGeneration
        )
        onPartialTranscript(nil)
        sawSpeech = speechAlreadyDetected
        silenceBeganAt = nil
        meterOpen = false
        meterReleaseDeadline = .distantPast
        state = .recording(mode, plan)
        onStatus(plan.isAmbient ? "Ambient recording…" : "Starting mic…")
        overlay.show(
            plan.isAmbient ? "Ambient recording" : "Starting mic",
            detail: "Speak now",
            level: meterLevel(audioCapture.currentDBFS(), threshold: plan.config.silenceThresholdDBFS)
        )

        engineStartTask?.cancel()
        engineStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                await self.appleStreamCleanupTask?.value
                guard self.recordingGeneration == generation else { return }
                if !plan.isAmbient {
                    await self.pauseAmbientMonitoringForShortcutRecording()
                }
                guard self.recordingGeneration == generation else { return }
                try await self.audioCapture.start(
                    preRollMilliseconds: plan.config.preRollMilliseconds,
                    inputDeviceID: plan.config.inputDeviceID
                )
                guard self.recordingGeneration == generation,
                      case .recording = self.state else { return }

                if plan.usesAppleStream && !plan.isAmbient {
                    try await self.asrService.startAppleStream(
                        detectSpeech: plan.usesSpeechActivityStop,
                        onEvent: { [weak self] event in
                            Task { @MainActor in
                                guard let self, self.recordingGeneration == generation else { return }
                                self.handleAppleEvent(event)
                            }
                        },
                        onDetection: { [weak self] detected in
                            Task { @MainActor in
                                guard let self, self.recordingGeneration == generation else { return }
                                self.handleSpeechDetection(detected)
                            }
                        }
                    )
                }

                let bufferHandler: ((AVAudioPCMBuffer) -> Void)? = plan.usesAppleStream ? { [asrService] buffer in
                    Task { try? await asrService.appendAppleBuffer(buffer) }
                } : nil
                self.audioCapture.beginRecording(
                    bufferHandler: bufferHandler,
                    replayPreRollToHandler: !plan.isAmbient
                )
                self.onStatus("Recording…")
                self.overlay.show(
                    "Recording",
                    detail: "Speak now",
                    level: self.meterLevel(
                        self.audioCapture.currentDBFS(),
                        threshold: plan.config.silenceThresholdDBFS
                    )
                )
                self.startSilenceLoop()
            } catch {
                guard self.recordingGeneration == generation else { return }
                let nsError = error as NSError
                DebugLog.write("recording start error domain=\(nsError.domain) code=\(nsError.code) detail=\(nsError.localizedDescription)")
                let resumeAmbient = self.shouldRunAmbientMonitoring()
                self.audioCapture.stop()
                if resumeAmbient {
                    await self.stopAmbientMonitoring()
                }
                guard self.recordingGeneration == generation else { return }
                self.recordingGeneration &+= 1
                self.state = .idle
                self.onStatus("Mic error: \(error.localizedDescription)")
                self.overlay.show("Mic error", detail: error.localizedDescription)
                if resumeAmbient {
                    if plan.ambientUpdateGeneration == self.ambientUpdateGeneration {
                        self.startAmbientMonitoring()
                    } else {
                        self.updateAmbientMode()
                    }
                }
            }
        }
    }

    private func stopAndTranscribe(reason: StopReason) async {
        guard case .recording = state else { return }
        let generation = recordingGeneration
        silenceTask?.cancel()
        silenceTask = nil
        let startTask = engineStartTask
        await startTask?.value
        engineStartTask = nil
        guard recordingGeneration == generation, case .recording = state else { return }
        let audioReady = await waitForFirstAudioBuffer(recordingGeneration: generation)
        DebugLog.write("recording stop audio-ready=\(audioReady ? "Y" : "N")")
        guard recordingGeneration == generation, case .recording(_, let plan) = state else { return }
        state = .processing
        onStatus("Transcribing…")
        overlay.show("Transcribing…", detail: reason.rawValue)

        defer { cleanupTemporaryAudio() }

        do {
            let resumeAmbient = shouldRunAmbientMonitoring()
            let audioURL = try audioCapture.finishRecording()
            temporaryAudioURLs.insert(audioURL)
            if plan.usesAppleStream {
                audioCapture.setMonitorBufferHandler(nil)
            }
            if !resumeAmbient {
                audioCapture.stop()
            }
            guard let transcriptionAudio = try await prepareVoiceprintAudio(audioURL: audioURL, plan: plan, resumeAmbient: resumeAmbient) else {
                return
            }
            temporaryAudioURLs.insert(transcriptionAudio.url)
            guard recordingGeneration == generation else { return }
            let rawText = try await transcribe(
                audioURL: transcriptionAudio.url,
                plan: plan,
                useAppleStreamFinal: transcriptionAudio.useAppleStreamFinal
            )
            guard recordingGeneration == generation else { return }
            let cleanedText = transcriptText(rawText, config: plan.config)
            let text = VocabularyCorrector.correct(cleanedText, entries: plan.config.vocabulary)
            guard !text.isEmpty else {
                throw NSError(domain: AppBrand.noSpeechErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "No speech detected."])
            }

            history.record(
                sourceText: cleanedText,
                text: text,
                backend: plan.config.preferredBackend,
                audioURL: transcriptionAudio.url
            )
            onTranscript(text)
            try await textInserter.insert(
                text,
                prePasteKeystroke: plan.pasteSettings.prePasteKeystroke,
                prePasteDelayMilliseconds: plan.pasteSettings.prePasteDelayMilliseconds,
                postPasteKeystroke: plan.pasteSettings.postPasteKeystroke,
                postPasteDelayMilliseconds: plan.pasteSettings.postPasteDelayMilliseconds
            )
            appleStreamTask = nil
            onPartialTranscript(nil)
            recordingGeneration &+= 1
            if plan.isAmbient { ambientStreamGeneration &+= 1 }
            state = .idle
            if resumeAmbient {
                resumeAmbientMonitoringAfterRecording(plan: plan)
            }
            onStatus(resumeAmbient ? "Ambient armed" : "Inserted + copied")
            overlay.show("Inserted + copied", detail: preview(text))
            overlay.hide(after: 1_200)
        } catch {
            guard recordingGeneration == generation else { return }
            let nsError = error as NSError
            DebugLog.write("recording completion error domain=\(nsError.domain) code=\(nsError.code) detail=\(nsError.localizedDescription)")
            appleStreamTask = nil
            onPartialTranscript(nil)
            let resumeAmbient = shouldRunAmbientMonitoring()
            if resumeAmbient {
                audioCapture.cancelRecording()
                audioCapture.setMonitorBufferHandler(nil)
                ambientCooldownUntil = Date().addingTimeInterval(1)
            } else {
                audioCapture.stop()
            }
            if plan.usesAppleStream {
                await asrService.cancelAppleStream()
            }
            recordingGeneration &+= 1
            if plan.isAmbient { ambientStreamGeneration &+= 1 }
            state = .idle
            if resumeAmbient {
                resumeAmbientMonitoringAfterRecording(plan: plan)
            }
            onStatus("Error: \(error.localizedDescription)")
            overlay.show(AppBrand.errorTitle, detail: error.localizedDescription)
        }
    }

    private func cleanupTemporaryAudio() {
        let urls = temporaryAudioURLs
        temporaryAudioURLs.removeAll()
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func waitForFirstAudioBuffer(
        recordingGeneration generation: Int,
        receivedAfter start: Date? = nil
    ) async -> Bool {
        func hasReadyBuffer() -> Bool {
            guard let age = audioCapture.secondsSinceLastBuffer() else { return false }
            guard let start else { return true }
            return age <= Date().timeIntervalSince(start)
        }

        guard !hasReadyBuffer() else { return true }

        // AVAudioEngine.start() can return before a cold USB input delivers its
        // first tap buffer. Give queued key-up handling time to receive one.
        let deadline = Date().addingTimeInterval(0.5)
        while recordingGeneration == generation, Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch {
                return false
            }
            if hasReadyBuffer() { return true }
        }
        return false
    }

    private func prepareVoiceprintAudio(audioURL: URL, plan: RecordingPlan, resumeAmbient: Bool) async throws -> TranscriptionAudio? {
        guard plan.config.voiceprintEnabled,
              let voiceprintVerifier,
              await voiceprintVerifier.hasProfile() else {
            return TranscriptionAudio(url: audioURL, useAppleStreamFinal: true)
        }
        onStatus("Extracting your speech…")
        overlay.show("Extracting your speech…")
        guard let extraction = try await voiceprintVerifier.extractOwnerSpeech(
            audioURL: audioURL,
            thresholdOverride: Float(plan.config.voiceprintThreshold)
        ) else {
            return TranscriptionAudio(url: audioURL, useAppleStreamFinal: true)
        }

        if plan.usesAppleStream {
            await asrService.cancelAppleStream()
            onPartialTranscript(nil)
        }
        guard let ownerAudioURL = extraction.audioURL else {
            appleStreamTask = nil
            onPartialTranscript(nil)
            recordingGeneration &+= 1
            if plan.isAmbient { ambientStreamGeneration &+= 1 }
            state = .idle
            if resumeAmbient {
                resumeAmbientMonitoringAfterRecording(plan: plan)
            }
            let best = extraction.bestDistance.map { String(format: "%.2f", $0) } ?? "none"
            let detail = "best distance \(best), threshold \(String(format: "%.2f", extraction.threshold))"
            onStatus("Ignored — no matching speaker")
            overlay.show("Ignored — no matching speaker", detail: detail)
            overlay.hide(after: 1_500)
            return nil
        }

        let detail = String(
            format: "%d/%d segments, %.1fs",
            extraction.keptSegmentCount,
            extraction.totalSegmentCount,
            extraction.keptDurationSeconds
        )
        onStatus("Transcribing your speech…")
        overlay.show("Transcribing your speech…", detail: detail)
        return TranscriptionAudio(url: ownerAudioURL, useAppleStreamFinal: false)
    }

    private func transcribe(audioURL: URL, plan: RecordingPlan, useAppleStreamFinal: Bool) async throws -> String {
        switch plan.config.preferredBackend {
        case .mlxParakeetV2:
            return try await asrService.transcribe(audioURL: audioURL)
        case .appleSpeechTranscriber:
            if useAppleStreamFinal && plan.usesAppleStream {
                return try await asrService.finishAppleStream()
            }
            return try await asrService.transcribeApple(audioURL: audioURL)
        }
    }

    private func resumeAmbientMonitoringAfterRecording(plan: RecordingPlan) {
        guard plan.ambientUpdateGeneration == ambientUpdateGeneration else { return }
        ambientCooldownUntil = Date().addingTimeInterval(1)
        if ambientTask == nil {
            startAmbientMonitoring()
        } else {
            startAmbientAppleStream()
        }
    }

    private func startAmbientAppleStream() {
        guard configProvider().preferredBackend.capabilities.supportsStreamingTranscription else { return }
        speechDetectedByDetector = false
        lastSpeechDetectedAt = nil
        ambientStreamGeneration += 1
        let generation = ambientStreamGeneration
        let updateGeneration = ambientUpdateGeneration
        let cleanupTask = appleStreamCleanupTask
        appleStreamTask?.cancel()
        appleStreamTask = Task { [asrService, audioCapture, weak self] in
            do {
                await cleanupTask?.value
                try Task.checkCancellation()
                try await asrService.startAppleStream(
                    detectSpeech: true,
                    onEvent: { [weak self] event in
                        Task { @MainActor in
                            guard let self,
                                  self.ambientStreamGeneration == generation,
                                  self.ambientUpdateGeneration == updateGeneration || self.isAmbientRecording else { return }
                            self.handleAppleEvent(event)
                        }
                    },
                    onDetection: { [weak self] detected in
                        Task { @MainActor in
                            guard let self,
                                  self.ambientStreamGeneration == generation,
                                  self.ambientUpdateGeneration == updateGeneration || self.isAmbientRecording else { return }
                            self.handleSpeechDetection(detected)
                        }
                    }
                )
                let installed = await MainActor.run { () -> Bool in
                    guard let self, self.ambientStreamGeneration == generation, !Task.isCancelled else { return false }
                    DebugLog.write("ambient installing apple stream monitor")
                    audioCapture.setMonitorBufferHandler { buffer in
                        Task {
                            do {
                                try await asrService.appendAppleBuffer(buffer)
                            } catch {
                                DebugLog.write("ambient apple append error=\(error.localizedDescription)")
                            }
                        }
                    }
                    return true
                }
                if !installed {
                    await asrService.cancelAppleStream()
                }
            } catch {
                await MainActor.run {
                    guard let self, self.ambientStreamGeneration == generation else { return }
                    self.audioCapture.setMonitorBufferHandler(nil)
                    self.ambientStreamGeneration &+= 1
                    self.ambientTask?.cancel()
                    self.ambientTask = nil
                    self.appleStreamTask = nil
                    self.ambientMicStartedAt = nil
                    if case .idle = self.state {
                        self.audioCapture.stop()
                    } else if case .recording = self.state {
                        self.audioCapture.stop()
                        self.silenceTask?.cancel()
                        self.silenceTask = nil
                        self.recordingGeneration &+= 1
                        self.state = .idle
                    }
                    self.onStatus("Apple Speech error: \(error.localizedDescription)")
                    self.overlay.show(AppBrand.errorTitle, detail: error.localizedDescription)
                }
            }
        }
    }

    private func handleAppleEvent(_ event: AppleSpeechStreamEvent) {
        let text: String
        switch event {
        case .partial(let partial), .final(let partial):
            text = partial
        }
        guard !text.isEmpty else { return }

        if shouldRunAmbientMonitoring() {
            switch state {
            case .idle:
                if isAboveNoiseFloor(configProvider()) {
                    speechDetectedByDetector = true
                    lastSpeechDetectedAt = Date()
                    DebugLog.write("ambient start transcriber event chars=\(text.count)")
                    startRecording(mode: .ambient, speechAlreadyDetected: true)
                }
            case .recording(.ambient, let plan):
                if isAboveNoiseFloor(plan.config) {
                    speechDetectedByDetector = true
                    lastSpeechDetectedAt = Date()
                }
            case .preparingAudio, .recording, .processing:
                break
            }
        }

        if case .recording(_, let plan) = state, isAboveNoiseFloor(plan.config) {
            speechDetectedByDetector = true
            lastSpeechDetectedAt = Date()
            sawSpeech = true
        }

        guard case .recording(_, let plan) = state else { return }
        guard plan.config.showLiveTranscript else { return }
        let displayText = transcriptText(text, config: plan.config)
        onPartialTranscript(displayText.isEmpty ? nil : displayText)
        overlay.updateDetail(displayText.isEmpty ? nil : preview(displayText))
    }

    private func handleSpeechDetection(_ detected: Bool) {
        speechDetectedByDetector = detected
        if detected {
            lastSpeechDetectedAt = Date()
        }
        DebugLog.write("speech detector speech=\(detected)")
    }

    private func pauseAmbientMonitoringForShortcutRecording() async {
        guard ambientTask != nil else { return }
        await stopAmbientMonitoring()
    }

    private func startAmbientMonitoring() {
        guard ambientTask == nil, shouldRunAmbientMonitoring() else { return }
        onStatus("Starting ambient mic…")
        ambientTask = Task { [weak self] in
            guard let self else { return }
            do {
                let config = self.configProvider().normalizedForBackend()
                try await self.audioCapture.start(
                    preRollMilliseconds: config.preRollMilliseconds,
                    inputDeviceID: config.inputDeviceID
                )
                guard !Task.isCancelled else { return }
                self.ambientMicStartedAt = Date()
                self.startAmbientAppleStream()
                self.onStatus("Ambient armed")
            } catch {
                await self.stopAmbientMonitoring()
                self.onStatus("Mic error: \(error.localizedDescription)")
                self.overlay.show("Mic error", detail: error.localizedDescription)
                return
            }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if self.shouldRestartAmbientMicForMissingInput() {
                    // The selected input is delivering no audio. Stop once and
                    // report it — do NOT loop restarting, which would rapidly
                    // tear down and recreate the SpeechAnalyzer stack and corrupt
                    // runtime state (later crashing on unrelated UI actions).
                    // The device watcher re-arms ambient via updateAmbientMode()
                    // when inputs actually change.
                    DebugLog.write("ambient stopping: no audio from selected input")
                    await self.stopAmbientMonitoring()
                    self.onStatus("No audio from microphone — choose another input")
                    self.overlay.show("No mic audio", detail: "Choose another input in settings")
                    self.overlay.hide(after: 4_000)
                    return
                }
                self.checkAmbientStart()
            }
        }
    }

    private func drainAmbientReconcileRequests() async {
        while ambientReconcilePending {
            ambientReconcilePending = false
            await reconcileAmbientMode()
        }
        ambientReconcileTask = nil
    }

    private func reconcileAmbientMode() async {
        guard case .idle = state else {
            ambientReconcilePending = true
            try? await Task.sleep(nanoseconds: 50_000_000)
            return
        }
        if shouldRunAmbientMonitoring() {
            if ambientTask == nil {
                startAmbientMonitoring()
            } else if case .idle = state {
                await stopAmbientMonitoring()
                if !ambientReconcilePending {
                    startAmbientMonitoring()
                }
            }
        } else {
            await stopAmbientMonitoring()
        }
    }

    private func stopAmbientMonitoring() async {
        ambientTask?.cancel()
        ambientTask = nil
        ambientStreamGeneration += 1
        appleStreamTask?.cancel()
        appleStreamTask = nil
        audioCapture.setMonitorBufferHandler(nil)
        speechDetectedByDetector = false
        lastSpeechDetectedAt = nil
        ambientCooldownUntil = nil
        ambientMicStartedAt = nil
        if case .idle = state {
            audioCapture.stop()
            onStatus("Ready — hold Right Command to dictate")
        }
        await asrService.cancelAppleStream()
    }

    private func checkAmbientStart() {
        guard shouldRunAmbientMonitoring() else { return }
        guard case .idle = state else { return }

        let now = Date()
        if let ambientCooldownUntil, now < ambientCooldownUntil { return }

        let level = audioCapture.currentDBFS()
        let recentSpeech = recentlyDetectedSpeech(within: 1.0) && isAboveNoiseFloor(configProvider())
        let nowLog = Date()
        if nowLog.timeIntervalSince(lastAmbientDecisionLogAt) >= 1 {
            lastAmbientDecisionLogAt = nowLog
            let age = lastSpeechDetectedAt.map { String(format: "%.2f", Date().timeIntervalSince($0)) } ?? "none"
            DebugLog.write(String(format: "ambient check recentSpeech=%@ detector=%@ age=%@ dbfs=%.1f", recentSpeech ? "true" : "false", speechDetectedByDetector ? "true" : "false", age, level))
        }

        if recentSpeech {
            DebugLog.write("ambient start speech detected")
            startRecording(mode: .ambient, speechAlreadyDetected: true)
        }
    }

    private func startSilenceLoop() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                self?.checkSilence()
            }
        }
    }

    private func checkSilence() {
        guard case .recording(_, let plan) = state else { return }

        let level = audioCapture.currentDBFS()
        overlay.updateLevel(meterLevel(level, threshold: plan.config.silenceThresholdDBFS))

        let now = Date()
        guard plan.config.silenceAutoStopEnabled || plan.isAmbient else { return }
        let speechActive = plan.usesSpeechActivityStop
            ? recentlyDetectedSpeech(within: 1.2) && level >= plan.config.silenceThresholdDBFS
            : level >= plan.config.silenceThresholdDBFS
        if speechActive {
            sawSpeech = true
            silenceBeganAt = nil
            return
        }

        guard sawSpeech else { return }
        if silenceBeganAt == nil {
            silenceBeganAt = now
            return
        }

        let silenceMs = Int(now.timeIntervalSince(silenceBeganAt ?? now) * 1_000)
        if silenceMs >= plan.config.silenceDurationMilliseconds {
            Task { await stopAndTranscribe(reason: .silence) }
        }
    }

    private func shouldRunAmbientMonitoring() -> Bool {
        let config = configProvider().normalizedForBackend()
        return config.ambientModeEnabled && config.preferredBackend.capabilities.supportsAmbient
    }

    private func shouldRestartAmbientMicForMissingInput() -> Bool {
        guard configProvider().ambientModeEnabled else { return false }
        guard case .idle = state else { return false }
        if let seconds = audioCapture.secondsSinceLastBuffer() {
            return seconds > 2
        }
        guard let ambientMicStartedAt else { return false }
        return Date().timeIntervalSince(ambientMicStartedAt) > missingInputTimeout
    }

    private func isAboveNoiseFloor(_ config: MimiConfig) -> Bool {
        audioCapture.peakDBFS(within: 1.5) >= config.normalizedForBackend().silenceThresholdDBFS
    }

    private func meterLevel(_ level: Double, threshold: Double) -> Double {
        let now = Date()
        if meterOpen {
            if level >= threshold {
                meterReleaseDeadline = now.addingTimeInterval(0.35)
                return level
            }
            if now < meterReleaseDeadline { return threshold }
            meterOpen = false
            return -120
        }

        // ponytail: fixed visual deadband; add a setting only if real-world tuning needs one.
        guard level >= threshold + 6 else { return -120 }
        meterOpen = true
        meterReleaseDeadline = now.addingTimeInterval(0.35)
        return level
    }

    private func recentlyDetectedSpeech(within seconds: TimeInterval) -> Bool {
        guard let lastSpeechDetectedAt else { return false }
        return Date().timeIntervalSince(lastSpeechDetectedAt) <= seconds
    }

    private func transcriptText(_ text: String, config: MimiConfig) -> String {
        config.fillerCleanupEnabled
            ? TranscriptCleaner.clean(text)
            : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func preview(_ text: String) -> String {
        if text.count <= 80 { return text }
        return String(text.prefix(77)) + "…"
    }
}
