@preconcurrency import AVFoundation
import Foundation
import SokkiSpeech

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
                "Could not find uv. Install uv or set SOKKI_UV_PATH."
            case .sidecarNotFound:
                "Could not find Sokki MLX sidecar."
            case .processNotRunning:
                "MLX sidecar is not running."
            case .invalidResponse(let line):
                "Invalid MLX sidecar response: \(line)"
            case .sidecarError(let message):
                message
            }
        }
    }

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputReaderTask: Task<Void, Never>?
    private var errorReaderTask: Task<Void, Never>?
    private var outputBuffer = Data()
    private var ready = false
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private let appleBackend = AppleSpeechTranscriberBackend()
    private var appleStreamStarting = false
    private var appleStreamActive = false
    private var applePendingBuffers: [AVAudioPCMBuffer] = []
    private let onStatus: @Sendable (String) -> Void

    init(onStatus: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onStatus = onStatus
    }

    func prepare(backend: ASRBackend = .mlxParakeetV2) async throws {
        switch backend {
        case .mlxParakeetV2:
            try await prepareMLX()
        case .appleSpeechTranscriber:
            onStatus("Preparing Apple SpeechTranscriber…")
            try await appleBackend.prepare()
            onStatus("Apple SpeechTranscriber ready")
        }
    }

    func startAppleStream(onEvent: @escaping AppleSpeechTranscriberBackend.EventHandler) async throws {
        appleStreamStarting = true
        appleStreamActive = false
        applePendingBuffers = []
        do {
            try await appleBackend.startStream(onEvent: onEvent)
            appleStreamActive = true
            appleStreamStarting = false
            let buffers = applePendingBuffers
            applePendingBuffers = []
            for buffer in buffers {
                try await appleBackend.append(buffer)
            }
        } catch {
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
        return try await appleBackend.finishStream()
    }

    func cancelAppleStream() async {
        appleStreamStarting = false
        appleStreamActive = false
        applePendingBuffers = []
        await appleBackend.cancelStream()
    }

    private func prepareMLX() async throws {
        if ready { return }
        if process == nil {
            try launchSidecar()
        }
        if ready { return }

        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        try await prepare()
        guard let inputPipe else { throw ASRError.processNotRunning }

        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            let payload: [String: Any] = [
                "id": requestID,
                "command": "transcribe",
                "path": audioURL.path
            ]

            do {
                let data = try JSONSerialization.data(withJSONObject: payload)
                inputPipe.fileHandleForWriting.write(data)
                inputPipe.fileHandleForWriting.write(Data([0x0A]))
            } catch {
                pending.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func launchSidecar() throws {
        let uvPath = try Self.findUVPath()
        let sidecarURL = try Self.findSidecarURL()

        onStatus("Loading MLX Parakeet v2…")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", "--python", "3.12", "--script", sidecarURL.path]

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PATH"] = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            environment["PATH"] ?? ""
        ].joined(separator: ":")
        environment["SOKKI_PARAKEET_MODEL"] = environment["SOKKI_PARAKEET_MODEL"] ?? "mlx-community/parakeet-tdt-0.6b-v2"
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        inputPipe = stdin
        outputPipe = stdout
        errorPipe = stderr

        outputReaderTask = Task.detached { [weak self, stdout] in
            while !Task.isCancelled {
                let data = stdout.fileHandleForReading.availableData
                guard !data.isEmpty else { break }
                await self?.consumeOutput(data)
            }
        }

        errorReaderTask = Task.detached { [stderr] in
            while !Task.isCancelled {
                let data = stderr.fileHandleForReading.availableData
                guard !data.isEmpty else { break }
                if let text = String(data: data, encoding: .utf8) {
                    NSLog("Sokki MLX: %@", text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { await self?.handleTermination(status: process.terminationStatus) }
        }

        try process.run()
        self.process = process
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)

        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String
        else {
            onStatus("Unexpected MLX output")
            return
        }

        NSLog("Sokki MLX event: %@", event)

        switch event {
        case "loading":
            onStatus("Loading MLX Parakeet v2…")
        case "ready":
            ready = true
            onStatus("Ready")
            readyContinuation?.resume()
            readyContinuation = nil
        case "result":
            guard let id = object["id"] as? String else { return }
            let text = object["text"] as? String ?? ""
            pending.removeValue(forKey: id)?.resume(returning: text)
        case "error":
            let message = object["message"] as? String ?? "MLX sidecar error"
            if let id = object["id"] as? String, let continuation = pending.removeValue(forKey: id) {
                continuation.resume(throwing: ASRError.sidecarError(message))
            } else {
                readyContinuation?.resume(throwing: ASRError.sidecarError(message))
                readyContinuation = nil
                onStatus("MLX error")
            }
        default:
            break
        }
    }

    private func handleTermination(status: Int32) {
        ready = false
        outputReaderTask?.cancel()
        errorReaderTask?.cancel()
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        outputReaderTask = nil
        errorReaderTask = nil
        let error = ASRError.sidecarError("MLX sidecar exited with status \(status).")
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
        pending.removeAll()
        onStatus("MLX stopped")
    }

    private static func findUVPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["SOKKI_UV_PATH"], FileManager.default.isExecutableFile(atPath: override) {
            return override
        }

        let candidates = [
            "/Users/adi/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
            "/usr/bin/uv"
        ]

        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }
        throw ASRError.uvNotFound
    }

    private static func findSidecarURL() throws -> URL {
        let fileManager = FileManager.default
        let bundleCandidate = Bundle.main.resourceURL?
            .appendingPathComponent("Sidecars", isDirectory: true)
            .appendingPathComponent("sokki_mlx_server.py")
        if let bundleCandidate, fileManager.fileExists(atPath: bundleCandidate.path) {
            return bundleCandidate
        }

        let repoCandidate = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("Sidecars", isDirectory: true)
            .appendingPathComponent("sokki_mlx_server.py")
        if fileManager.fileExists(atPath: repoCandidate.path) {
            return repoCandidate
        }

        throw ASRError.sidecarNotFound
    }
}
