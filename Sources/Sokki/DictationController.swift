@preconcurrency import AVFoundation
import Foundation
import SokkiSpeech

@MainActor
final class DictationController {
    enum RecordingMode {
        case pressing(startedAt: Date)
        case toggle
        case ambient
    }

    enum State {
        case idle
        case recording(RecordingMode)
        case processing
    }

    private enum StopReason: String {
        case released = "Released"
        case stopped = "Stopped"
        case silence = "Silence"
    }

    private let configProvider: () -> SokkiConfig
    private let audioCapture: AudioCapture
    private let asrService: ASRService
    private let textInserter: TextInserter
    private let history: HistoryStore
    private let overlay: OverlayWindowController
    private let onStatus: (String) -> Void
    private let onTranscript: (String?) -> Void
    private let onPartialTranscript: (String?) -> Void

    private var state: State = .idle
    private var silenceTask: Task<Void, Never>?
    private var ambientTask: Task<Void, Never>?
    private var speechDetectedByDetector = false
    private var lastSpeechDetectedAt: Date?
    private var sawSpeech = false
    private var silenceBeganAt: Date?
    private var ambientSpeechBeganAt: Date?
    private var ambientCooldownUntil: Date?
    private var engineStartTask: Task<Void, Never>?
    private var appleStreamTask: Task<Void, Never>?
    private var lastAmbientDecisionLogAt = Date.distantPast

    init(
        configProvider: @escaping () -> SokkiConfig,
        audioCapture: AudioCapture,
        asrService: ASRService,
        textInserter: TextInserter,
        history: HistoryStore,
        overlay: OverlayWindowController,
        onStatus: @escaping (String) -> Void,
        onTranscript: @escaping (String?) -> Void,
        onPartialTranscript: @escaping (String?) -> Void
    ) {
        self.configProvider = configProvider
        self.audioCapture = audioCapture
        self.asrService = asrService
        self.textInserter = textInserter
        self.history = history
        self.overlay = overlay
        self.onStatus = onStatus
        self.onTranscript = onTranscript
        self.onPartialTranscript = onPartialTranscript
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
        case .recording(.toggle), .recording(.ambient):
            Task { await stopAndTranscribe(reason: .stopped) }
        case .recording(.pressing), .processing:
            break
        }
    }

    func hotkeyUp() {
        guard case .recording(.pressing(let startedAt)) = state else { return }

        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        if elapsedMs < configProvider().tapThresholdMilliseconds {
            state = .recording(.toggle)
            onStatus("Recording — tap Right Command again to stop")
            overlay.show("Recording", detail: "Tap Right Command again or pause", level: audioCapture.currentDBFS())
        } else {
            Task { await stopAndTranscribe(reason: .released) }
        }
    }

    func updateAmbientMode() {
        if configProvider().ambientModeEnabled {
            if ambientTask == nil {
                startAmbientMonitoring()
            } else if case .idle = state {
                stopAmbientMonitoring()
                startAmbientMonitoring()
            }
        } else {
            stopAmbientMonitoring()
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
        guard case .recording = state else { return }
        let config = configProvider()
        silenceTask?.cancel()
        silenceTask = nil
        engineStartTask?.cancel()
        engineStartTask = nil
        if config.ambientModeEnabled {
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
        if config.preferredBackend == .appleSpeechTranscriber {
            Task { [weak self, asrService] in
                await asrService.cancelAppleStream()
                await MainActor.run {
                    guard let self, config.ambientModeEnabled else { return }
                    self.startAmbientAppleStream()
                }
            }
        }
        onStatus(config.ambientModeEnabled ? "Ambient armed" : "Cancelled")
        overlay.show("Cancelled")
        overlay.hide(after: 700)
    }

    private func startRecording(mode: RecordingMode, speechAlreadyDetected: Bool = false) {
        let config = configProvider()
        onPartialTranscript(nil)
        sawSpeech = speechAlreadyDetected
        silenceBeganAt = nil
        state = .recording(mode)
        let isAmbient = if case .ambient = mode { true } else { false }
        onStatus(isAmbient ? "Ambient recording…" : "Starting mic…")
        overlay.show(isAmbient ? "Ambient recording" : "Starting mic", detail: "Speak now", level: audioCapture.currentDBFS())

        engineStartTask?.cancel()
        engineStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.audioCapture.start(preRollMilliseconds: config.preRollMilliseconds)
                guard case .recording = self.state else { return }

                let usesAmbientAppleStream = isAmbient && config.preferredBackend == .appleSpeechTranscriber
                let bufferHandler: ((AVAudioPCMBuffer) -> Void)? = usesAmbientAppleStream ? { [asrService] buffer in
                    Task { try? await asrService.appendAppleBuffer(buffer) }
                } : nil
                self.audioCapture.beginRecording(
                    bufferHandler: bufferHandler,
                    replayPreRollToHandler: !usesAmbientAppleStream
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
        guard case .recording(let mode) = state else { return }
        let isAmbientRecording = if case .ambient = mode { true } else { false }
        silenceTask?.cancel()
        silenceTask = nil
        let startTask = engineStartTask
        await startTask?.value
        engineStartTask = nil
        guard case .recording = state else { return }
        state = .processing
        onStatus("Transcribing…")
        overlay.show("Transcribing…", detail: reason.rawValue)

        do {
            let config = configProvider()
            let audioURL = try audioCapture.finishRecording()
            let usesAmbientAppleStream = isAmbientRecording && config.preferredBackend == .appleSpeechTranscriber
            if usesAmbientAppleStream {
                audioCapture.setMonitorBufferHandler(nil)
            }
            if !config.ambientModeEnabled {
                audioCapture.stop()
            }
            let rawText: String
            switch config.preferredBackend {
            case .mlxParakeetV2:
                rawText = try await asrService.transcribe(audioURL: audioURL)
            case .appleSpeechTranscriber:
                if usesAmbientAppleStream {
                    rawText = try await asrService.finishAppleStream()
                } else {
                    rawText = try await asrService.transcribeApple(audioURL: audioURL)
                }
            }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw NSError(domain: AppBrand.noSpeechErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: "No speech detected."])
            }

            history.record(text)
            onTranscript(text)
            try await textInserter.insert(
                text,
                pressReturn: config.pressEnterAfterPaste,
                enterDelayMilliseconds: config.postPasteEnterDelayMilliseconds
            )
            appleStreamTask = nil
            onPartialTranscript(nil)
            state = .idle
            if config.ambientModeEnabled {
                ambientCooldownUntil = Date().addingTimeInterval(1)
                if config.preferredBackend == .appleSpeechTranscriber {
                    startAmbientAppleStream()
                }
            }
            onStatus(config.ambientModeEnabled ? "Ambient armed" : "Inserted + copied")
            overlay.show("Inserted + copied", detail: preview(text))
            overlay.hide(after: 1_200)
        } catch {
            appleStreamTask = nil
            onPartialTranscript(nil)
            let config = configProvider()
            let usesAmbientAppleStream = isAmbientRecording && config.preferredBackend == .appleSpeechTranscriber
            if config.ambientModeEnabled {
                audioCapture.cancelRecording()
                audioCapture.setMonitorBufferHandler(nil)
                ambientCooldownUntil = Date().addingTimeInterval(1)
                if usesAmbientAppleStream {
                    await asrService.cancelAppleStream()
                }
            } else {
                audioCapture.stop()
            }
            state = .idle
            if config.ambientModeEnabled && config.preferredBackend == .appleSpeechTranscriber {
                startAmbientAppleStream()
            }
            onStatus("Error: \(error.localizedDescription)")
            overlay.show(AppBrand.errorTitle, detail: error.localizedDescription)
        }
    }

    private func startAmbientAppleStream() {
        guard configProvider().preferredBackend == .appleSpeechTranscriber else { return }
        speechDetectedByDetector = false
        lastSpeechDetectedAt = nil
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
                            self?.handleAmbientDetection(detected)
                        }
                    }
                )
                await MainActor.run {
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
                }
            } catch {
                Task { @MainActor in
                    guard let self else { return }
                    self.audioCapture.setMonitorBufferHandler(nil)
                    if case .recording = self.state {
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

        if configProvider().ambientModeEnabled {
            switch state {
            case .idle:
                speechDetectedByDetector = true
                lastSpeechDetectedAt = Date()
                DebugLog.write("ambient start transcriber event chars=\(text.count)")
                startRecording(mode: .ambient, speechAlreadyDetected: true)
            case .recording(.ambient):
                speechDetectedByDetector = true
                lastSpeechDetectedAt = Date()
            case .recording, .processing:
                break
            }
        }

        guard case .recording = state else { return }
        onPartialTranscript(text)
        overlay.updateDetail(preview(text))
    }

    private func handleAmbientDetection(_ detected: Bool) {
        speechDetectedByDetector = detected
        if detected {
            lastSpeechDetectedAt = Date()
        }
        DebugLog.write("ambient detector speech=\(detected)")
    }

    private func startAmbientMonitoring() {
        guard ambientTask == nil else { return }
        onStatus("Starting ambient mic…")
        ambientTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.audioCapture.start(preRollMilliseconds: self.configProvider().preRollMilliseconds)
                guard !Task.isCancelled else { return }
                if self.configProvider().preferredBackend == .appleSpeechTranscriber {
                    self.startAmbientAppleStream()
                }
                self.onStatus("Ambient armed")
            } catch {
                self.onStatus("Mic error: \(error.localizedDescription)")
                self.overlay.show("Mic error", detail: error.localizedDescription)
                return
            }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                self.checkAmbientStart()
            }
        }
    }

    private func stopAmbientMonitoring() {
        ambientTask?.cancel()
        ambientTask = nil
        appleStreamTask?.cancel()
        appleStreamTask = nil
        Task { [asrService] in await asrService.cancelAppleStream() }
        audioCapture.setMonitorBufferHandler(nil)
        speechDetectedByDetector = false
        lastSpeechDetectedAt = nil
        ambientSpeechBeganAt = nil
        ambientCooldownUntil = nil
        if case .idle = state {
            audioCapture.stop()
            onStatus("Ready — hold Right Command to dictate")
        }
    }

    private func checkAmbientStart() {
        let config = configProvider()
        guard config.ambientModeEnabled else { return }
        guard case .idle = state else { return }

        let now = Date()
        if let ambientCooldownUntil, now < ambientCooldownUntil { return }

        let level = audioCapture.currentDBFS()
        let recentSpeech: Bool
        if config.preferredBackend == .appleSpeechTranscriber {
            recentSpeech = recentlyDetectedSpeech(within: 1.0)
        } else if level >= config.silenceThresholdDBFS {
            if ambientSpeechBeganAt == nil {
                ambientSpeechBeganAt = now
                return
            }
            let speechMs = Int(now.timeIntervalSince(ambientSpeechBeganAt ?? now) * 1_000)
            recentSpeech = speechMs >= min(config.minUtteranceMilliseconds, 250)
        } else {
            ambientSpeechBeganAt = nil
            recentSpeech = false
        }

        let nowLog = Date()
        if nowLog.timeIntervalSince(lastAmbientDecisionLogAt) >= 1 {
            lastAmbientDecisionLogAt = nowLog
            let age = lastSpeechDetectedAt.map { String(format: "%.2f", Date().timeIntervalSince($0)) } ?? "none"
            DebugLog.write(String(format: "ambient check recentSpeech=%@ detector=%@ age=%@ dbfs=%.1f", recentSpeech ? "true" : "false", speechDetectedByDetector ? "true" : "false", age, level))
        }

        if recentSpeech {
            ambientSpeechBeganAt = nil
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
        guard case .recording(let mode) = state else { return }
        let isAmbientRecording = if case .ambient = mode { true } else { false }

        let level = audioCapture.currentDBFS()
        overlay.updateLevel(level)

        let now = Date()
        let config = configProvider()
        guard config.silenceAutoStopEnabled || isAmbientRecording else { return }
        let speechActive = isAmbientRecording && config.preferredBackend == .appleSpeechTranscriber
            ? recentlyDetectedSpeech(within: 1.2)
            : level >= config.silenceThresholdDBFS
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
        if silenceMs >= config.silenceDurationMilliseconds {
            Task { await stopAndTranscribe(reason: .silence) }
        }
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
