import XCTest
@testable import Mimi

final class AudioInputDeviceTests: XCTestCase {
    func testMissingSelectedInputDeviceFallsBackToSystemDefault() {
        let devices = [AudioInputDevice(id: "built-in", name: "Built-in Microphone")]

        XCTAssertEqual(AudioInputDevice.validSelection("built-in", in: devices), "built-in")
        XCTAssertNil(AudioInputDevice.validSelection("missing-usb-mic", in: devices))
        XCTAssertNil(AudioInputDevice.validSelection(nil, in: devices))
        XCTAssertNil(AudioInputDevice.validSelection("", in: devices))
    }

    @MainActor
    func testCaptureStartGateWaitsForInFlightStart() async throws {
        let gate = AudioStartGate()
        try await gate.acquire()
        var replacementAcquired = false
        let replacement = Task { @MainActor in
            try await gate.acquire()
            replacementAcquired = true
        }

        for _ in 0..<100 where gate.waitingCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(gate.waitingCount, 1)
        XCTAssertFalse(replacementAcquired)

        gate.release()
        try await replacement.value
        XCTAssertTrue(replacementAcquired)
        gate.release()
    }

    func testCaptureUsesFreshEngineWhenCoreAudioReassignsDeviceAfterWake() {
        XCTAssertTrue(AudioCapture.requiresFreshEngine(
            routeConfigured: true,
            configuredInputDeviceID: "webcam",
            effectiveInputDeviceID: "webcam",
            configuredAudioDeviceID: 222,
            effectiveAudioDeviceID: 231
        ))
    }

    func testCaptureUsesFreshEngineAfterRouteChangeOrFailedStart() {
        XCTAssertFalse(AudioCapture.requiresFreshEngine(
            routeConfigured: true,
            configuredInputDeviceID: "mic-a",
            effectiveInputDeviceID: "mic-a",
            configuredAudioDeviceID: 222,
            effectiveAudioDeviceID: 222
        ))
        XCTAssertTrue(AudioCapture.requiresFreshEngine(
            routeConfigured: true,
            configuredInputDeviceID: "mic-a",
            effectiveInputDeviceID: "mic-b"
        ))
        XCTAssertTrue(AudioCapture.requiresFreshEngine(
            routeConfigured: false,
            configuredInputDeviceID: "mic-a",
            effectiveInputDeviceID: "mic-a"
        ))
    }
}
