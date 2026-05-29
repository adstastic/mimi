import Foundation

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

    private var state: State = .idle
    private var silenceTask: Task<Void, Never>?
    private var sawSpeech = false
    private var silenceBeganAt: Date?

    init(
        configProvider: @escaping () -> SokkiConfig,
        audioCapture: AudioCapture,
        asrService: ASRService,
        textInserter: TextInserter,
        history: HistoryStore,
        overlay: OverlayWindowController,
        onStatus: @escaping (String) -> Void,
        onTranscript: @escaping (String?) -> Void
    ) {
        self.configProvider = configProvider
        self.audioCapture = audioCapture
        self.asrService = asrService
        self.textInserter = textInserter
        self.history = history
        self.overlay = overlay
        self.onStatus = onStatus
        self.onTranscript = onTranscript
    }

    func prepareASR() {
        Task {
            do {
                onStatus("Loading MLX Parakeet v2…")
                try await asrService.prepare()
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
        audioCapture.cancelRecording()
        state = .idle
        onStatus("Cancelled")
        overlay.show("Cancelled")
        overlay.hide(after: 700)
    }

    private func startRecording(mode: RecordingMode) {
        audioCapture.beginRecording()
        sawSpeech = false
        silenceBeganAt = nil
        state = .recording(mode)
        onStatus("Recording…")
        overlay.show("Recording", detail: "Speak now", level: audioCapture.currentDBFS())
        startSilenceLoop()
    }

    private func stopAndTranscribe(reason: StopReason) async {
        guard case .recording = state else { return }
        silenceTask?.cancel()
        silenceTask = nil
        state = .processing
        onStatus("Transcribing…")
        overlay.show("Transcribing…", detail: reason.rawValue)

        do {
            let audioURL = try audioCapture.finishRecording()
            let rawText = try await asrService.transcribe(audioURL: audioURL)
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw NSError(domain: "Sokki", code: 1, userInfo: [NSLocalizedDescriptionKey: "No speech detected."])
            }

            history.record(text)
            onTranscript(text)
            let config = configProvider()
            try await textInserter.insert(
                text,
                pressReturn: config.pressEnterAfterPaste,
                enterDelayMilliseconds: config.postPasteEnterDelayMilliseconds
            )
            state = .idle
            onStatus("Inserted + copied")
            overlay.show("Inserted + copied", detail: preview(text))
            overlay.hide(after: 1_200)
        } catch {
            state = .idle
            onStatus("Error: \(error.localizedDescription)")
            overlay.show("Sokki error", detail: error.localizedDescription)
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
