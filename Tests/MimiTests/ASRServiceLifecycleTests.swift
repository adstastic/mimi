@preconcurrency import AVFoundation
import XCTest
import MimiSpeech
@testable import Mimi

final class ASRServiceLifecycleTests: XCTestCase {
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
