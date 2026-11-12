@preconcurrency import AVFoundation
import Foundation
import MimiSpeech

protocol AppleSpeechServing: Sendable {
    func prepare() async throws
    func transcribe(audioURL: URL) async throws -> String
    func startStream(
        detectSpeech: Bool,
        onEvent: @escaping AppleSpeechTranscriberBackend.EventHandler,
        onDetection: AppleSpeechTranscriberBackend.DetectionHandler?
    ) async throws
    func append(_ buffer: AVAudioPCMBuffer) async throws
    func finishStream() async throws -> String
    func cancelStream() async
}

extension AppleSpeechTranscriberBackend: AppleSpeechServing {}

actor ASRService {
    enum ASRError: LocalizedError {
        case uvNotFound
        case sidecarNotFound
        case processNotRunning
        case invalidResponse(String)
        case sidecarError(String)

        var errorDescription: String? {
            switch self {
            case .uvNotFound:
                "Could not find uv. Install uv or set MIMI_UV_PATH."
            case .sidecarNotFound:
                AppBrand.mlxSidecarMissingMessage
            case .processNotRunning:
                "MLX sidecar is not running."
            case .invalidResponse(let line):
                "Invalid MLX sidecar response: \(line)"
            case .sidecarError(let message):
                message
            }
        }
    }

    private var workers: [ASRBackend: MLXSidecar] = [:]
    private var selectedBackend: ASRBackend = .mlxParakeetV2
    private let appleBackend: any AppleSpeechServing
    private let makeMLXProcess: @Sendable (ASRBackend) throws -> Process
    private var appleStreamStarting = false
    private var appleStreamActive = false
    private var applePendingBuffers: [AVAudioPCMBuffer] = []
    private var appleLifecycleBusy = false
    private var appleLifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    private let onStatus: @Sendable (String) -> Void

    init(
        appleBackend: any AppleSpeechServing = AppleSpeechTranscriberBackend(),
        makeMLXProcess: @escaping @Sendable (ASRBackend) throws -> Process = { try MLXSidecar.makeProcess(backend: $0) },
        onStatus: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.appleBackend = appleBackend
        self.makeMLXProcess = makeMLXProcess
        self.onStatus = onStatus
    }

    func prepare(backend: ASRBackend = .mlxParakeetV2) async throws {
        selectedBackend = backend
        switch backend {
        case .mlxParakeetV2, .mlxQwen3ASR17B:
            try await worker(for: backend).prepare()
        case .appleSpeechTranscriber:
            reportStatus("Preparing Apple SpeechTranscriber…", backend: backend)
            try await appleBackend.prepare()
            reportStatus("Apple SpeechTranscriber ready", backend: backend)
        }
    }

    func transcribe(
        audioURL: URL,
        backend: ASRBackend = .mlxParakeetV2,
        context: String = ""
    ) async throws -> String {
        switch backend {
        case .appleSpeechTranscriber:
            return try await transcribeApple(audioURL: audioURL)
        case .mlxParakeetV2, .mlxQwen3ASR17B:
            return try await worker(for: backend).transcribe(audioURL: audioURL, context: context)
        }
    }

    private func worker(for backend: ASRBackend) -> MLXSidecar {
        if let worker = workers[backend] { return worker }
        let worker = MLXSidecar(backend: backend, makeProcess: makeMLXProcess) { [weak self] status in
            await self?.reportStatus(status, backend: backend)
        }
        workers[backend] = worker
        return worker
    }

    private func reportStatus(_ status: String, backend: ASRBackend) {
        guard backend == selectedBackend else { return }
        onStatus(status)
    }

    func transcribeApple(audioURL: URL) async throws -> String {
        try await appleBackend.transcribe(audioURL: audioURL)
    }

    func startAppleStream(
        detectSpeech: Bool = false,
        onEvent: @escaping AppleSpeechTranscriberBackend.EventHandler,
        onDetection: AppleSpeechTranscriberBackend.DetectionHandler? = nil
    ) async throws {
        await acquireAppleLifecycle()
        defer { releaseAppleLifecycle() }
        appleStreamStarting = true
        appleStreamActive = false
        applePendingBuffers = []
        var backendStarted = false
        do {
            try Task.checkCancellation()
            DebugLog.write("apple stream starting detectSpeech=\(detectSpeech)")
            try await appleBackend.startStream(detectSpeech: detectSpeech, onEvent: onEvent, onDetection: onDetection)
            backendStarted = true
            try Task.checkCancellation()
            DebugLog.write("apple stream started detectSpeech=\(detectSpeech)")
            appleStreamActive = true
            appleStreamStarting = false
            let buffers = applePendingBuffers
            applePendingBuffers = []
            for buffer in buffers {
                try Task.checkCancellation()
                try await appleBackend.append(buffer)
            }
        } catch {
            if backendStarted {
                await appleBackend.cancelStream()
            }
            appleStreamStarting = false
            appleStreamActive = false
            applePendingBuffers = []
            throw error
        }
    }

    func appendAppleBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        if appleStreamStarting {
            if applePendingBuffers.count < 50 {
                applePendingBuffers.append(buffer)
            }
            return
        }
        guard appleStreamActive else { return }
        try await appleBackend.append(buffer)
    }

    func finishAppleStream() async throws -> String {
        appleStreamStarting = false
        appleStreamActive = false
        applePendingBuffers = []
        await acquireAppleLifecycle()
        defer { releaseAppleLifecycle() }
        appleStreamStarting = false
        appleStreamActive = false
        applePendingBuffers = []
        return try await appleBackend.finishStream()
    }

    func cancelAppleStream() async {
        appleStreamStarting = false
        appleStreamActive = false
        applePendingBuffers = []
        await acquireAppleLifecycle()
        defer { releaseAppleLifecycle() }
        appleStreamStarting = false
        appleStreamActive = false
        applePendingBuffers = []
        await appleBackend.cancelStream()
        appleStreamStarting = false
        appleStreamActive = false
        applePendingBuffers = []
    }

    private func acquireAppleLifecycle() async {
        if !appleLifecycleBusy {
            appleLifecycleBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            appleLifecycleWaiters.append(continuation)
        }
    }

    private func releaseAppleLifecycle() {
        if appleLifecycleWaiters.isEmpty {
            appleLifecycleBusy = false
        } else {
            appleLifecycleWaiters.removeFirst().resume()
        }
    }
}
