@preconcurrency import AVFoundation
import XCTest
import Darwin
import MimiSpeech
import Synchronization
@testable import Mimi

final class ASRServiceLifecycleTests: XCTestCase {
    func testConcurrentMLXPreloadsAllCompleteOnReadyOrFailure() async throws {
        for event in ["ready", "error", "exit"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let gate = directory.appendingPathComponent("release")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", """
                while [ ! -f "$1" ]; do sleep 0.01; done
                if [ "$2" = exit ]; then exit 1; fi
                printf '{"event":"%s","message":"load failed"}\\n' "$2"
                while read -r line; do :; done
                """, "mlx-fixture", gate.path, event]
            let service = ASRService(makeMLXProcess: { _ in process })
            defer { if process.isRunning { process.terminate() } }
            let finished = expectation(description: "Both preload callers finish on \(event)")
            finished.expectedFulfillmentCount = 2
            for _ in 0..<2 {
                Task {
                    do {
                        try await service.prepare(backend: .mlxParakeetV2)
                        XCTAssertEqual(event, "ready")
                    } catch {
                        XCTAssertNotEqual(event, "ready")
                    }
                    finished.fulfill()
                }
            }
            let started = await waitUntil { process.isRunning }
            XCTAssertTrue(started)
            try await Task.sleep(nanoseconds: 50_000_000)
            try Data().write(to: gate)
            await fulfillment(of: [finished], timeout: 2)
        }
    }

    func testBackendWorkersPreloadOnceAndRemainIsolatedAfterOldWorkerExits() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = MLXFixtureFactory(directory: directory)
        defer { factory.stop() }
        let service = ASRService(makeMLXProcess: { backend in try factory.make(backend) }, onStatus: { factory.recordStatus($0) })

        async let first: Void = service.prepare(backend: .mlxQwen3ASR17B)
        async let second: Void = service.prepare(backend: .mlxQwen3ASR17B)
        let qwenStarted = await waitUntil { factory.count(.mlxQwen3ASR17B) == 1 }
        XCTAssertTrue(qwenStarted)
        XCTAssertEqual(factory.count(.mlxParakeetV2), 0, "Unselected model must remain unloaded")
        try Data().write(to: factory.gate(.mlxQwen3ASR17B, "ready"))
        try await first
        try await second
        XCTAssertEqual(factory.count(.mlxQwen3ASR17B), 1)

        let parakeetPreload = Task { try await service.prepare(backend: .mlxParakeetV2) }
        let parakeetStarted = await waitUntil { factory.count(.mlxParakeetV2) == 1 }
        XCTAssertTrue(parakeetStarted)
        try Data().write(to: factory.gate(.mlxParakeetV2, "ready"))
        try await parakeetPreload.value
        try await service.prepare(backend: .mlxQwen3ASR17B)

        let qwenResult = Task {
            try await service.transcribe(audioURL: URL(fileURLWithPath: "/qwen.wav"), backend: .mlxQwen3ASR17B, context: "Vocabulary: PyTorch.")
        }
        let parakeetResult = Task {
            try await service.transcribe(audioURL: URL(fileURLWithPath: "/parakeet.wav"), backend: .mlxParakeetV2)
        }
        let received = await waitUntil {
            factory.hasRequest(.mlxQwen3ASR17B) && factory.hasRequest(.mlxParakeetV2)
        }
        XCTAssertTrue(received)
        let request = try factory.request(.mlxQwen3ASR17B)
        XCTAssertEqual(request["path"] as? String, "/qwen.wav")
        XCTAssertEqual(request["context"] as? String, "Vocabulary: PyTorch.")
        XCTAssertEqual(try factory.request(.mlxParakeetV2)["path"] as? String, "/parakeet.wav")

        factory.terminate(.mlxParakeetV2)
        if case .success = await parakeetResult.result { XCTFail("Terminated worker succeeded") }
        XCTAssertEqual(factory.lastStatus, "MLX Qwen3-ASR 1.7B ready", "Old worker status must not overwrite selected backend")
        try Data().write(to: factory.gate(.mlxQwen3ASR17B, "result"))
        let text = try await qwenResult.value
        XCTAssertEqual(text, ASRBackend.mlxQwen3ASR17B.rawValue)
        let secondText = try await service.transcribe(audioURL: URL(fileURLWithPath: "/again.wav"), backend: .mlxQwen3ASR17B)
        XCTAssertEqual(secondText, text)
        XCTAssertEqual(factory.count(.mlxQwen3ASR17B), 1)
    }

    func testExitSettlesPreloadEvenWhenDescendantKeepsStdoutOpen() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 30 & printf '%s' \"$!\" > \"$1\"; exit 1", "mlx-fixture", pidFile.path]
        let service = ASRService(makeMLXProcess: { _ in process })
        let finished = expectation(description: "Exit settles preload without waiting for descendant stdout EOF")
        let preload = Task {
            do {
                try await service.prepare(backend: .mlxQwen3ASR17B)
                XCTFail("Exited worker unexpectedly became ready")
            } catch {}
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)
        if let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8)) {
            Darwin.kill(pid, SIGTERM)
        }
        await preload.value
    }

    func testSuspendedReadyStatusCannotReleaseReplacementPreload() async throws {
        let firstProcess = Process()
        firstProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        firstProcess.arguments = ["-c", #"printf '{"event":"ready"}\n'; while read -r line; do :; done"#]
        let replacementProcess = Process()
        replacementProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        replacementProcess.arguments = ["-c", #"printf '{"event":"loading"}\n'; read -r line; printf '{"event":"ready"}\n'; while read -r line; do :; done"#]
        let processes = Mutex([firstProcess, replacementProcess])
        let statusGate = MLXStatusGate()
        let statusSuspended = expectation(description: "First ready status suspended")
        let stopped = expectation(description: "First termination handled")
        let replacementLoading = expectation(description: "Replacement launched and awaiting ready")
        let firstFinished = expectation(description: "First preload settled")
        let replacementFinished = expectation(description: "Replacement preload settled")
        let prematureCompletion = expectation(description: "Replacement must not finish before its own ready")
        prematureCompletion.isInverted = true
        let sentReplacementReady = Mutex(false)
        let sidecar = MLXSidecar(backend: .mlxQwen3ASR17B, makeProcess: { _ in
            processes.withLock { $0.removeFirst() }
        }, onStatus: { status in
            switch status {
            case "MLX Qwen3-ASR 1.7B ready":
                await statusGate.wait { statusSuspended.fulfill() }
            case "MLX Qwen3-ASR 1.7B stopped":
                stopped.fulfill()
            case "Loading MLX Qwen3-ASR 1.7B…":
                replacementLoading.fulfill()
            default:
                break
            }
        })
        defer {
            Task { await statusGate.open() }
            for process in [firstProcess, replacementProcess] where process.isRunning { process.terminate() }
        }
        let first = Task {
            _ = try? await sidecar.prepare()
            firstFinished.fulfill()
        }
        defer { first.cancel() }
        guard await XCTWaiter.fulfillment(of: [statusSuspended], timeout: 2) == .completed else {
            XCTFail("First ready status did not suspend")
            return
        }
        if firstProcess.isRunning { firstProcess.terminate() }
        guard await XCTWaiter.fulfillment(of: [stopped, firstFinished], timeout: 2) == .completed else {
            XCTFail("First worker did not settle on termination")
            return
        }

        let replacement = Task {
            do {
                try await sidecar.prepare()
                if !sentReplacementReady.withLock({ $0 }) { prematureCompletion.fulfill() }
            } catch {
                XCTFail("Replacement preload failed: \(error)")
            }
            replacementFinished.fulfill()
        }
        defer { replacement.cancel() }
        guard await XCTWaiter.fulfillment(of: [replacementLoading], timeout: 2) == .completed else {
            XCTFail("Replacement worker did not launch")
            return
        }
        await statusGate.open()
        await fulfillment(of: [prematureCompletion], timeout: 0.2)

        sentReplacementReady.withLock { $0 = true }
        let input = try XCTUnwrap(replacementProcess.standardInput as? Pipe)
        try input.fileHandleForWriting.write(contentsOf: Data("ready\n".utf8))
        await fulfillment(of: [replacementFinished], timeout: 2)
    }

    func testFailedLaunchCanRetrySameBackend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = MLXFixtureFactory(directory: directory)
        defer { factory.stop() }
        let service = ASRService(makeMLXProcess: { try factory.make($0, failFirstLaunch: true) })
        do {
            try await service.prepare(backend: .mlxQwen3ASR17B)
            XCTFail("Missing executable unexpectedly launched")
        } catch {}
        try Data().write(to: factory.gate(.mlxQwen3ASR17B, "ready"))
        try Data().write(to: factory.gate(.mlxQwen3ASR17B, "result"))
        try await service.prepare(backend: .mlxQwen3ASR17B)
        let text = try await service.transcribe(audioURL: URL(fileURLWithPath: "/retry.wav"), backend: .mlxQwen3ASR17B)
        XCTAssertEqual(text, ASRBackend.mlxQwen3ASR17B.rawValue)
        XCTAssertEqual(factory.count(.mlxQwen3ASR17B), 2)
    }

    func testTerminatedBackendCanRestartWithoutOldRequestState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = MLXFixtureFactory(directory: directory)
        defer { factory.stop() }
        let service = ASRService(makeMLXProcess: { try factory.make($0) })
        try Data().write(to: factory.gate(.mlxQwen3ASR17B, "ready"))
        try await service.prepare(backend: .mlxQwen3ASR17B)
        let first = Task {
            try await service.transcribe(audioURL: URL(fileURLWithPath: "/first.wav"), backend: .mlxQwen3ASR17B)
        }
        let received = await waitUntil { factory.hasRequest(.mlxQwen3ASR17B) }
        XCTAssertTrue(received)
        factory.terminate(.mlxQwen3ASR17B)
        if case .success = await first.result { XCTFail("Terminated request succeeded") }
        try Data().write(to: factory.gate(.mlxQwen3ASR17B, "result"))
        try await service.prepare(backend: .mlxQwen3ASR17B)
        let text = try await service.transcribe(audioURL: URL(fileURLWithPath: "/replacement.wav"), backend: .mlxQwen3ASR17B)
        XCTAssertEqual(text, ASRBackend.mlxQwen3ASR17B.rawValue)
        XCTAssertEqual(factory.count(.mlxQwen3ASR17B), 2)
    }

    func testQwenSmokeTranscribesFixtureWhenEnabled() async throws {
        guard let path = ProcessInfo.processInfo.environment["MIMI_QWEN_SMOKE_AUDIO"], !path.isEmpty else {
            throw XCTSkip("Set MIMI_QWEN_SMOKE_AUDIO to opt into real local Qwen transcription")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let service = ASRService()
        try await service.prepare(backend: .mlxQwen3ASR17B)
        let text = try await service.transcribe(
            audioURL: URL(fileURLWithPath: path), backend: .mlxQwen3ASR17B, context: "Vocabulary: Mimi."
        )
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("Qwen smoke transcript: \(text)")
    }

    func testRestartWaitsForPreviousStartBeforeCancelling() async {
        let backend = SlowStartingAppleBackend()
        let service = ASRService(appleBackend: backend)
        let firstStart = Task {
            try await service.startAppleStream(detectSpeech: true, onEvent: { _ in })
        }

        let started = await waitUntil { await backend.isStarting }
        XCTAssertTrue(started)
        await service.cancelAppleStream()

        var restartError: Error?
        do {
            try await service.startAppleStream(detectSpeech: false, onEvent: { _ in })
        } catch {
            restartError = error
        }
        _ = try? await firstStart.value

        XCTAssertNil(restartError, "Restart rejected: \(restartError?.localizedDescription ?? "unknown error")")
    }

    func testCancelLeavesStreamInactiveAfterInFlightStart() async throws {
        let backend = SlowStartingAppleBackend()
        let service = ASRService(appleBackend: backend)
        let firstStart = Task {
            try await service.startAppleStream(detectSpeech: true, onEvent: { _ in })
        }

        let started = await waitUntil { await backend.isStarting }
        XCTAssertTrue(started)
        await service.cancelAppleStream()
        _ = try? await firstStart.value

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        try await service.appendAppleBuffer(buffer)

        let appendCount = await backend.appendCount
        XCTAssertEqual(appendCount, 0)
    }

    func testPendingBufferFailureCancelsStartedBackend() async throws {
        let backend = SlowStartingAppleBackend(failsAppend: true)
        let service = ASRService(appleBackend: backend)
        let start = Task {
            try await service.startAppleStream(detectSpeech: true, onEvent: { _ in })
        }

        let started = await waitUntil { await backend.isStarting }
        XCTAssertTrue(started)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        try await service.appendAppleBuffer(buffer)
        let result = await start.result

        if case .success = result {
            XCTFail("Start unexpectedly succeeded after pending buffer failed")
        }
        let cancelCount = await backend.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testCanceledInFlightStartCancelsBackendBeforeReturning() async {
        let backend = SlowStartingAppleBackend(ignoresCancellation: true)
        let service = ASRService(appleBackend: backend)
        let start = Task {
            try await service.startAppleStream(detectSpeech: true, onEvent: { _ in })
        }

        let started = await waitUntil { await backend.isStarting }
        XCTAssertTrue(started)
        start.cancel()
        let result = await start.result

        if case .success = result {
            XCTFail("Canceled start unexpectedly succeeded")
        }
        let cancelCount = await backend.cancelCount
        XCTAssertEqual(cancelCount, 1)
    }

    func testCanceledQueuedStartNeverReachesBackend() async {
        let backend = SlowStartingAppleBackend()
        let service = ASRService(appleBackend: backend)
        let firstStart = Task {
            try await service.startAppleStream(detectSpeech: true, onEvent: { _ in })
        }

        let started = await waitUntil { await backend.isStarting }
        XCTAssertTrue(started)
        let canceledStart = Task {
            try await service.startAppleStream(detectSpeech: false, onEvent: { _ in })
        }
        canceledStart.cancel()

        _ = try? await firstStart.value
        _ = await canceledStart.result

        let startCount = await backend.startCount
        XCTAssertEqual(startCount, 1)
        await service.cancelAppleStream()
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await predicate()
    }
}

private final class MLXFixtureFactory: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var processes: [ASRBackend: [Process]] = [:]
    private var statuses: [String] = []

    init(directory: URL) { self.directory = directory }

    var lastStatus: String? { lock.withLock { statuses.last } }
    func recordStatus(_ status: String) { lock.withLock { statuses.append(status) } }
    func count(_ backend: ASRBackend) -> Int { lock.withLock { processes[backend]?.count ?? 0 } }
    func gate(_ backend: ASRBackend, _ name: String) -> URL {
        directory.appendingPathComponent("\(backend.rawValue).\(name)")
    }
    func hasRequest(_ backend: ASRBackend) -> Bool {
        FileManager.default.fileExists(atPath: gate(backend, "request").path)
    }
    func request(_ backend: ASRBackend) throws -> [String: Any] {
        let data = try Data(contentsOf: gate(backend, "request"))
        let line = data.split(separator: 10).first ?? Data.SubSequence()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
    }
    func terminate(_ backend: ASRBackend) {
        lock.withLock { processes[backend]?.forEach { if $0.isRunning { $0.terminate() } } }
    }
    func stop() {
        lock.withLock { processes.values.flatMap { $0 }.forEach { if $0.isRunning { $0.terminate() } } }
    }
    func make(_ backend: ASRBackend, failFirstLaunch: Bool = false) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: failFirstLaunch && count(backend) == 0 ? "/nonexistent-mimi-test" : "/bin/sh")
        process.arguments = ["-c", #"""
            while [ ! -f "$1" ]; do sleep 0.01; done
            printf '{"event":"ready"}\n'
            while IFS= read -r line; do
                printf '%s\n' "$line" >> "$3"
                while [ ! -f "$2" ]; do sleep 0.01; done
                id=${line#*\"id\":\"}
                id=${id%%\"*}
                printf '{"event":"result","id":"%s","text":"%s"}\n' "$id" "$4"
            done
            """#, "mlx-fixture", gate(backend, "ready").path, gate(backend, "result").path,
            gate(backend, "request").path, backend.rawValue]
        lock.withLock { processes[backend, default: []].append(process) }
        return process
    }
}

private actor MLXStatusGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait(onSuspended: @Sendable () -> Void) async {
        guard !isOpen else { return }
        await withCheckedContinuation {
            continuation = $0
            onSuspended()
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor SlowStartingAppleBackend: AppleSpeechServing {
    private let ignoresCancellation: Bool
    private let failsAppend: Bool
    private(set) var isStarting = false
    private(set) var startCount = 0
    private(set) var appendCount = 0
    private(set) var cancelCount = 0

    init(ignoresCancellation: Bool = false, failsAppend: Bool = false) {
        self.ignoresCancellation = ignoresCancellation
        self.failsAppend = failsAppend
    }

    func prepare() async throws {}

    func transcribe(audioURL: URL) async throws -> String { "" }

    func startStream(
        detectSpeech: Bool,
        onEvent: @escaping AppleSpeechTranscriberBackend.EventHandler,
        onDetection: AppleSpeechTranscriberBackend.DetectionHandler?
    ) async throws {
        startCount += 1
        guard !isStarting else {
            throw NSError(
                domain: "FakeSpeechAnalyzer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Request was rejected"]
            )
        }
        isStarting = true
        defer { isStarting = false }
        if ignoresCancellation {
            try? await Task.sleep(nanoseconds: 100_000_000)
        } else {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) async throws {
        appendCount += 1
        if failsAppend {
            throw NSError(domain: "FakeSpeechAnalyzer", code: 2)
        }
    }

    func finishStream() async throws -> String { "" }

    func cancelStream() async {
        cancelCount += 1
    }
}
