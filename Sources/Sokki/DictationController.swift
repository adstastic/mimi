@preconcurrency import AVFoundation
import Foundation
import SokkiSpeech

@MainActor
final class DictationController {
    enum RecordingMode {
        case pressing(startedAt: Date)
        case toggle
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
    private var sawSpeech = false
    private var silenceBeganAt: Date?
    private var engineStartTask: Task<Void, Never>?
    private var appleStreamTask: Task<Void, Never>?

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
                overlay.show("Sokki error", detail: error.localizedDescription)
            }
        }
    }

    func hotkeyDown() {
        switch state {
        case .idle:
            startRecording(mode: .pressing(startedAt: Date()))
        case .recording(.toggle):
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
        silenceTask?.cancel()
        silenceTask = nil
        engineStartTask?.cancel()
        engineStartTask = nil
        audioCapture.stop()
        if configProvider().preferredBackend == .appleSpeechTranscriber {
            Task { await asrService.cancelAppleStream() }
        }
        appleStreamTask?.cancel()
        appleStreamTask = nil
        onPartialTranscript(nil)
        state = .idle
        onStatus("Cancelled")
        overlay.show("Cancelled")
        overlay.hide(after: 700)
    }

    private func startRecording(mode: RecordingMode) {
        let config = configProvider()
        onPartialTranscript(nil)
        sawSpeech = false
        silenceBeganAt = nil
        state = .recording(mode)
        onStatus("Starting mic…")
        overlay.show("Starting mic", detail: "Speak now", level: audioCapture.currentDBFS())

        engineStartTask?.cancel()
        engineStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.audioCapture.start(preRollMilliseconds: config.preRollMilliseconds)
                guard case .recording = self.state else { return }

                if config.preferredBackend == .appleSpeechTranscriber {
                    self.startAppleStream()
                }

                let bufferHandler: ((AVAudioPCMBuffer) -> Void)? = config.preferredBackend == .appleSpeechTranscriber ? { [asrService] buffer in
                    Task { try? await asrService.appendAppleBuffer(buffer) }
                } : nil
                self.audioCapture.beginRecording(bufferHandler: bufferHandler)
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
        guard case .recording = state else { return }
        state = .processing
        onStatus("Transcribing…")
        overlay.show("Transcribing…", detail: reason.rawValue)

        do {
            let config = configProvider()
            let audioURL = try audioCapture.finishRecording()
            audioCapture.stop()
            let rawText: String
            switch config.preferredBackend {
            case .mlxParakeetV2:
                rawText = try await asrService.transcribe(audioURL: audioURL)
            case .appleSpeechTranscriber:
                await appleStreamTask?.value
                rawText = try await asrService.finishAppleStream()
            }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw NSError(domain: "Sokki", code: 1, userInfo: [NSLocalizedDescriptionKey: "No speech detected."])
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
            onStatus("Inserted + copied")
            overlay.show("Inserted + copied", detail: preview(text))
            overlay.hide(after: 1_200)
        } catch {
            appleStreamTask = nil
            onPartialTranscript(nil)
            audioCapture.stop()
            state = .idle
            onStatus("Error: \(error.localizedDescription)")
            overlay.show("Sokki error", detail: error.localizedDescription)
        }
    }

    private func startAppleStream() {
        appleStreamTask?.cancel()
        appleStreamTask = Task { [asrService, weak self] in
            do {
                try await asrService.startAppleStream { [weak self] event in
                    Task { @MainActor in
                        self?.handleAppleEvent(event)
                    }
                }
            } catch {
                Task { @MainActor in
                    guard let self, case .recording = self.state else { return }
                    self.audioCapture.stop()
                    self.silenceTask?.cancel()
                    self.silenceTask = nil
                    self.state = .idle
                    self.onStatus("Apple Speech error: \(error.localizedDescription)")
                    self.overlay.show("Sokki error", detail: error.localizedDescription)
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
        onPartialTranscript(text)
        overlay.updateDetail(preview(text))
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
        guard case .recording = state else { return }

        let level = audioCapture.currentDBFS()
        overlay.updateLevel(level)

        let now = Date()
        let config = configProvider()
        guard config.silenceAutoStopEnabled else { return }
        if level >= config.silenceThresholdDBFS {
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

    private func preview(_ text: String) -> String {
        if text.count <= 80 { return text }
        return String(text.prefix(77)) + "…"
    }
}
