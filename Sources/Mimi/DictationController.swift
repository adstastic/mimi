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
        let pressesReturnOnStart: Bool
        let pressesReturnAfterPaste: Bool

        init(config: MimiConfig, isAmbient: Bool) {
            let normalizedConfig = config.normalizedForBackend()
            let capabilities = normalizedConfig.preferredBackend.capabilities
            self.config = normalizedConfig
            self.isAmbient = isAmbient
            usesAppleStream = capabilities.usesStreamingTranscription(
                isAmbient: isAmbient,
                silenceDetectionMode: normalizedConfig.silenceDetectionMode
            )
            usesSpeechActivityStop = capabilities.usesSpeechActivityStop(normalizedConfig.silenceDetectionMode)
            pressesReturnOnStart = isAmbient && normalizedConfig.ambientPressEnterOnStart
            pressesReturnAfterPaste = isAmbient || normalizedConfig.pressEnterAfterPaste
        }
    }

    private enum State {
        case idle
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
    private let textInserter: TextInserter
    private let history: HistoryStore
    private let overlay: OverlayShowing
    private let onStatus: (String) -> Void
    private let onTranscript: (String?) -> Void
    private let onPartialTranscript: (String?) -> Void
    private let missingInputTimeout: TimeInterval

    private var state: State = .idle
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
    private var ambientStreamGeneration = 0
    private var ambientReconcileTask: Task<Void, Never>?
    private var ambientReconcilePending = false
    private var lastAmbientDecisionLogAt = Date.distantPast

    init(
        configProvider: @escaping () -> MimiConfig,
        audioCapture: AudioCapturing,
        asrService: ASRServicing,
        voiceprintVerifier: VoiceprintVerifying? = nil,
        textInserter: TextInserter,
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
        case .processing:
            break
        }
    }

    func hotkeyUp() {
        guard case .recording(.pressing(let startedAt), let plan) = state else { return }

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        if elapsedMs < plan.config.tapThresholdMilliseconds {
            state = .recording(.toggle, plan)
            onStatus("Recording — tap Right Command again to stop")
            overlay.show("Recording", detail: "Tap Right Command again or pause", level: audioCapture.currentDBFS())
        } else {
            Task { await stopAndTranscribe(reason: .released) }
        }
    }

    func updateAmbientMode() {
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

    func cancelRecording() {
        guard case .recording(_, let plan) = state else { return }
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
            Task { [weak self, asrService] in
                await asrService.cancelAppleStream()
                await MainActor.run {
                    guard let self, resumeAmbient else { return }
                    self.resumeAmbientMonitoringAfterRecording()
                }
            }
        }
        onStatus(resumeAmbient ? "Ambient armed" : "Cancelled")
        overlay.show("Cancelled")
        overlay.hide(after: 700)
    }

    private func startRecording(mode: RecordingMode, speechAlreadyDetected: Bool = false) {
        let isAmbient = if case .ambient = mode { true } else { false }
        let plan = RecordingPlan(config: configProvider(), isAmbient: isAmbient)
        onPartialTranscript(nil)
        sawSpeech = speechAlreadyDetected
        silenceBeganAt = nil
        state = .recording(mode, plan)
        onStatus(plan.isAmbient ? "Ambient recording…" : "Starting mic…")
        overlay.show(plan.isAmbient ? "Ambient recording" : "Starting mic", detail: "Speak now", level: audioCapture.currentDBFS())

        engineStartTask?.cancel()
        engineStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !plan.isAmbient {
                    await self.pauseAmbientMonitoringForShortcutRecording()
                } else if plan.pressesReturnOnStart {
                    try self.textInserter.pressReturn()
                }
                try await self.audioCapture.start(
                    preRollMilliseconds: plan.config.preRollMilliseconds,
                    inputDeviceID: plan.config.inputDeviceID
                )
                guard case .recording = self.state else { return }

                if plan.usesAppleStream && !plan.isAmbient {
                    try await self.asrService.startAppleStream(
                        detectSpeech: plan.usesSpeechActivityStop,
                        onEvent: { [weak self] event in
                            Task { @MainActor in
                                self?.handleAppleEvent(event)
                            }
                        },
                        onDetection: { [weak self] detected in
                            Task { @MainActor in
                                self?.handleSpeechDetection(detected)
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
                self.overlay.show("Recording", detail: "Speak now", level: self.audioCapture.currentDBFS())
                self.startSilenceLoop()
            } catch {
                self.state = .idle
                self.onStatus("Mic error: \(error.localizedDescription)")
                self.overlay.show("Mic error", detail: error.localizedDescription)
            }
        }
    }

    private func stopAndTranscribe(reason: StopReason) async {
        guard case .recording = state else { return }
        silenceTask?.cancel()
        silenceTask = nil
        let startTask = engineStartTask
        await startTask?.value
        engineStartTask = nil
        guard case .recording(_, let plan) = state else { return }
        state = .processing
        onStatus("Transcribing…")
        overlay.show("Transcribing…", detail: reason.rawValue)

        do {
            let resumeAmbient = shouldRunAmbientMonitoring()
            let audioURL = try audioCapture.finishRecording()
            if plan.usesAppleStream {
                audioCapture.setMonitorBufferHandler(nil)
            }
            if !resumeAmbient {
                audioCapture.stop()
            }
            guard let transcriptionAudio = try await prepareVoiceprintAudio(audioURL: audioURL, plan: plan, resumeAmbient: resumeAmbient) else {
                return
            }
            let rawText = try await transcribe(
                audioURL: transcriptionAudio.url,
                plan: plan,
                useAppleStreamFinal: transcriptionAudio.useAppleStreamFinal
            )
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw NSError(domain: AppBrand.noSpeechErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "No speech detected."])
            }

            history.record(text)
            onTranscript(text)
            try await textInserter.insert(
                text,
                pressReturn: plan.pressesReturnAfterPaste,
                enterDelayMilliseconds: plan.config.postPasteEnterDelayMilliseconds
            )
            appleStreamTask = nil
            onPartialTranscript(nil)
            state = .idle
            if resumeAmbient {
                resumeAmbientMonitoringAfterRecording()
            }
            onStatus(resumeAmbient ? "Ambient armed" : "Inserted + copied")
            overlay.show("Inserted + copied", detail: preview(text))
            overlay.hide(after: 1_200)
        } catch {
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
            state = .idle
            if resumeAmbient {
                resumeAmbientMonitoringAfterRecording()
            }
            onStatus("Error: \(error.localizedDescription)")
            overlay.show(AppBrand.errorTitle, detail: error.localizedDescription)
        }
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
            state = .idle
            if resumeAmbient {
                resumeAmbientMonitoringAfterRecording()
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

    private func resumeAmbientMonitoringAfterRecording() {
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
        appleStreamTask?.cancel()
        appleStreamTask = Task { [asrService, audioCapture, weak self] in
            do {
                try await asrService.startAppleStream(
                    detectSpeech: true,
                    onEvent: { [weak self] event in
                        Task { @MainActor in
                            self?.handleAppleEvent(event)
                        }
                    },
                    onDetection: { [weak self] detected in
                        Task { @MainActor in
                            self?.handleSpeechDetection(detected)
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
            case .recording, .processing:
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
        onPartialTranscript(text)
        overlay.updateDetail(preview(text))
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
        overlay.updateLevel(level)

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
        audioCapture.currentDBFS() >= config.normalizedForBackend().silenceThresholdDBFS
    }

    private func recentlyDetectedSpeech(within seconds: TimeInterval) -> Bool {
        guard let lastSpeechDetectedAt else { return false }
        return Date().timeIntervalSince(lastSpeechDetectedAt) <= seconds
    }

    private func preview(_ text: String) -> String {
        if text.count <= 80 { return text }
        return String(text.prefix(77)) + "…"
    }
}
