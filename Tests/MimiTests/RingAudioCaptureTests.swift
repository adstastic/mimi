import AVFoundation
import RingKit
import XCTest
@testable import Mimi

@MainActor
final class RingAudioCaptureTests: XCTestCase {
    private func pcm16Packet(id: UInt16, sample: Int16, count: Int = 160) -> RingNotification {
        var payload = Data(capacity: count * 2)
        for _ in 0..<count {
            payload.append(UInt8(truncatingIfNeeded: sample))
            payload.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return .audioPacket(RingAudioPacket(packetID: id, sessionID: 1, fragmentIndex: 0, payload: payload))
    }

    func testPacketsFeedPreRollThenRecordingAndLevels() throws {
        let capture = RingAudioCapture(codec: .pcm16)
        // Pre-roll capacity without touching CoreBluetooth: 20 ms = 320 samples.
        capture.setPreRoll(milliseconds: 20)

        capture.handle(pcm16Packet(id: 0, sample: 8_000))
        capture.handle(pcm16Packet(id: 1, sample: 8_000))
        capture.handle(pcm16Packet(id: 2, sample: 8_000))
        XCTAssertGreaterThan(capture.currentDBFS(), -120)
        XCTAssertNotNil(capture.secondsSinceLastBuffer())

        var replayed: [AVAudioFrameCount] = []
        capture.beginRecording(bufferHandler: { replayed.append($0.frameLength) }, replayPreRollToHandler: true)
        XCTAssertEqual(replayed, [320], "pre-roll replays only the last 20 ms")

        capture.handle(pcm16Packet(id: 3, sample: 8_000))
        XCTAssertEqual(replayed, [320, 160])

        let url = try capture.finishRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 480)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
    }

    func testAudioAfterStartIsKeptUntilRecordingBegins() throws {
        let capture = RingAudioCapture(codec: .pcm16)
        capture.setPreRoll(milliseconds: 20) // 320 samples, less than the 480 sent after START

        capture.handle(.recordingEvent(RingRecordingEvent(timestampMs: 0, marker: .start, sessionID: 1, packetCount: 0)))
        capture.handle(pcm16Packet(id: 0, sample: 8_000))
        capture.handle(pcm16Packet(id: 1, sample: 8_000))
        capture.handle(pcm16Packet(id: 2, sample: 8_000))

        var replayed: [AVAudioFrameCount] = []
        capture.beginRecording(bufferHandler: { replayed.append($0.frameLength) }, replayPreRollToHandler: true)
        XCTAssertEqual(replayed, [480], "everything after START is speech and must not be trimmed")

        capture.handle(pcm16Packet(id: 3, sample: 8_000))
        let url = try capture.finishRecording()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 640)
    }

    func testMarkersDriveCallbacks() async {
        let capture = RingAudioCapture(codec: .pcm16)
        var events: [String] = []
        capture.onPressBegan = { events.append("began") }
        capture.onPressEnded = { events.append("ended") }
        capture.onPressCancelled = { events.append("cancelled") }

        func event(_ marker: RingRecordingMarker) -> RingNotification {
            .recordingEvent(RingRecordingEvent(timestampMs: 0, marker: marker, sessionID: 1, packetCount: 0))
        }
        capture.handle(event(.start))
        capture.handle(event(.stop))
        capture.handle(event(.altStart))
        capture.handle(event(.cancel))
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(events, ["began", "ended", "began", "cancelled"])
    }
}

@MainActor
final class RoutingAudioCaptureTests: XCTestCase {
    private final class Fake: AudioCapturing {
        var starts: [String?] = []
        var stops = 0
        func start(preRollMilliseconds: Int, inputDeviceID: String?) async throws { starts.append(inputDeviceID) }
        func setMonitorBufferHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {}
        func beginRecording(bufferHandler: ((AVAudioPCMBuffer) -> Void)?, replayPreRollToHandler: Bool) {}
        func finishRecording() throws -> URL { URL(fileURLWithPath: "/dev/null") }
        func cancelRecording() {}
        func stop() { stops += 1 }
        func currentDBFS() -> Double { -120 }
        func peakDBFS(within seconds: TimeInterval) -> Double { -120 }
        func secondsSinceLastBuffer() -> TimeInterval? { nil }
    }

    func testRoutesByDeviceIDAndStopsPreviousSource() async throws {
        let mic = Fake()
        let ring = Fake()
        let router = RoutingAudioCapture(mic: mic, ring: ring)

        try await router.start(preRollMilliseconds: 0, inputDeviceID: nil)
        XCTAssertTrue(router.active === mic)
        XCTAssertEqual(mic.starts, [nil])

        try await router.start(preRollMilliseconds: 0, inputDeviceID: RingAudioCapture.deviceID)
        XCTAssertTrue(router.active === ring)
        XCTAssertEqual(ring.starts, [RingAudioCapture.deviceID])
        XCTAssertEqual(mic.stops, 1)

        try await router.start(preRollMilliseconds: 0, inputDeviceID: "usb")
        XCTAssertTrue(router.active === mic)
        XCTAssertEqual(ring.stops, 1)
        XCTAssertEqual(mic.starts, [nil, "usb"])
    }
}
