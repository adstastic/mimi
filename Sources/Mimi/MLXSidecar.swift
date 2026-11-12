import Foundation

actor MLXSidecar {
    private typealias ASRError = ASRService.ASRError

    private let backend: ASRBackend
    private let makeProcess: @Sendable (ASRBackend) throws -> Process
    private let onStatus: @Sendable (String) async -> Void
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputReaderTask: Task<Void, Never>?
    private var errorReaderTask: Task<Void, Never>?
    private var outputBuffer = Data()
    private var ready = false
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var pending: [String: CheckedContinuation<String, Error>] = [:]

    init(
        backend: ASRBackend,
        makeProcess: @escaping @Sendable (ASRBackend) throws -> Process,
        onStatus: @escaping @Sendable (String) async -> Void
    ) {
        self.backend = backend
        self.makeProcess = makeProcess
        self.onStatus = onStatus
    }

    deinit {
        if let process, process.isRunning { process.terminate() }
        try? inputPipe?.fileHandleForWriting.close()
        outputReaderTask?.cancel()
        errorReaderTask?.cancel()
    }

    func prepare() async throws {
        if ready {
            await onStatus("\(backend.displayName) ready")
            return
        }
        if process == nil { try launchSidecar() }
        try await withCheckedThrowingContinuation { continuation in
            readyContinuations.append(continuation)
        }
    }

    func transcribe(audioURL: URL, context: String) async throws -> String {
        try await prepare()
        guard let inputPipe else { throw ASRError.processNotRunning }
        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            let payload: [String: Any] = [
                "id": requestID,
                "command": "transcribe",
                "path": audioURL.path,
                "context": context
            ]
            do {
                var data = try JSONSerialization.data(withJSONObject: payload)
                data.append(0x0A)
                try inputPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                pending.removeValue(forKey: requestID)?.resume(throwing: error)
            }
        }
    }

    private func launchSidecar() throws {
        let process = try makeProcess(backend)
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] exited in
            Task { await self?.handleTermination(exited) }
        }
        do {
            try process.run()
        } catch {
            for pipe in [stdin, stdout, stderr] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            throw error
        }
        self.process = process
        inputPipe = stdin
        outputReaderTask = Task.detached { [weak self, stdout, process] in
            while !Task.isCancelled {
                let data = stdout.fileHandleForReading.availableData
                guard !data.isEmpty else { break }
                await self?.consumeOutput(data, from: process)
            }
        }
        errorReaderTask = Task.detached { [stderr, backend] in
            while !Task.isCancelled {
                let data = stderr.fileHandleForReading.availableData
                guard !data.isEmpty else { break }
                if let text = String(data: data, encoding: .utf8) {
                    NSLog("%@ %@: %@", AppBrand.name, backend.displayName, text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
    }

    private func consumeOutput(_ data: Data, from source: Process) async {
        guard process === source else { return }
        outputBuffer.append(data)
        while process === source, let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            await handleLine(line)
        }
    }

    private func handleLine(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String
        else {
            await onStatus("Unexpected \(backend.displayName) output")
            return
        }
        NSLog("%@ %@ event: %@", AppBrand.name, backend.displayName, event)
        switch event {
        case "loading":
            await onStatus("Loading \(backend.displayName)…")
        case "ready":
            ready = true
            let continuations = readyContinuations
            readyContinuations.removeAll()
            for continuation in continuations { continuation.resume() }
            await onStatus("\(backend.displayName) ready")
        case "result":
            guard let id = object["id"] as? String else { return }
            pending.removeValue(forKey: id)?.resume(returning: object["text"] as? String ?? "")
        case "error":
            let message = object["message"] as? String ?? "MLX sidecar error"
            if let id = object["id"] as? String {
                pending.removeValue(forKey: id)?.resume(throwing: ASRError.sidecarError(message))
            } else {
                for continuation in readyContinuations { continuation.resume(throwing: ASRError.sidecarError(message)) }
                readyContinuations.removeAll()
                await onStatus("\(backend.displayName) error")
            }
        default:
            break
        }
    }

    private func handleTermination(_ exited: Process) async {
        guard process === exited else { return }
        // Descendants can retain stdout after exit. Settle callers without waiting for EOF.
        ready = false
        outputReaderTask?.cancel()
        errorReaderTask?.cancel()
        process = nil
        try? inputPipe?.fileHandleForWriting.close()
        inputPipe = nil
        outputReaderTask = nil
        errorReaderTask = nil
        outputBuffer.removeAll()
        let error = ASRError.sidecarError("\(backend.displayName) sidecar exited with status \(exited.terminationStatus).")
        for continuation in readyContinuations { continuation.resume(throwing: error) }
        readyContinuations.removeAll()
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending.removeAll()
        await onStatus("\(backend.displayName) stopped")
    }

    static func makeProcess(backend: ASRBackend) throws -> Process {
        let uvPath = try findUVPath()
        let sidecarURL = try findSidecarURL(backend: backend)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: uvPath)
        process.arguments = ["run", "--python", "3.12", "--script", sidecarURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PATH"] = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin", environment["PATH"] ?? ""
        ].joined(separator: ":")
        process.environment = environment
        return process
    }

    private static func findUVPath() throws -> String {
        if let override = ProcessInfo.processInfo.environment["MIMI_UV_PATH"], FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let candidates = ["/Users/adi/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv", "/usr/bin/uv"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return path }
        throw ASRError.uvNotFound
    }

    private static func findSidecarURL(backend: ASRBackend) throws -> URL {
        let name: String
        switch backend {
        case .mlxParakeetV2: name = "mimi_mlx_server.py"
        case .mlxQwen3ASR17B: name = "mimi_qwen_server.py"
        case .appleSpeechTranscriber: throw ASRError.sidecarNotFound
        }
        let fileManager = FileManager.default
        let bundleCandidate = Bundle.main.resourceURL?
            .appendingPathComponent("Sidecars", isDirectory: true).appendingPathComponent(name)
        if let bundleCandidate, fileManager.fileExists(atPath: bundleCandidate.path) { return bundleCandidate }
        let repoCandidate = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent("Sidecars", isDirectory: true).appendingPathComponent(name)
        if fileManager.fileExists(atPath: repoCandidate.path) { return repoCandidate }
        throw ASRError.sidecarNotFound
    }
}
