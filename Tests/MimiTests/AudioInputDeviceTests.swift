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

    func testAutomaticInputAvoidsBluetoothWhenBuiltInMicrophoneIsAvailable() {
        let devices = [
            AudioInputDevice(id: "airpods", name: "AirPods Pro", transport: .bluetooth),
            AudioInputDevice(id: "built-in", name: "MacBook Pro Microphone", transport: .builtIn),
        ]

        XCTAssertEqual(
            AudioInputDevice.automaticSelection(defaultInputDeviceID: "airpods", in: devices),
            "built-in"
        )
        XCTAssertEqual(
            AudioInputDevice.resolvedSelection(
                "airpods",
                defaultInputDeviceID: "airpods",
                in: devices
            ),
            "airpods",
            "An explicit Bluetooth microphone selection must remain explicit"
        )
    }

    func testAutomaticInputKeepsNonBluetoothDefaultAndBluetoothFallback() {
        let devices = [
            AudioInputDevice(id: "usb", name: "Studio Microphone", transport: .other),
            AudioInputDevice(id: "built-in", name: "MacBook Pro Microphone", transport: .builtIn),
            AudioInputDevice(id: "airpods", name: "AirPods Pro", transport: .bluetooth),
        ]

        XCTAssertEqual(
            AudioInputDevice.automaticSelection(defaultInputDeviceID: "usb", in: devices),
            "usb"
        )
        XCTAssertEqual(
            AudioInputDevice.automaticSelection(
                defaultInputDeviceID: "airpods",
                in: [AudioInputDevice(id: "airpods", name: "AirPods Pro", transport: .bluetooth)]
            ),
            "airpods"
        )
    }

    func testMimiEchoReferenceDoesNotChangeSelectableInputDevices() {
        let microphone = AudioInputDevice(id: "built-in", name: "Built-in Microphone")
        let first = AudioInputDevice.selectable([
            microphone,
            AudioInputDevice(id: "\(SystemAudioTap.aggregateUIDPrefix)first", name: "Mimi Echo Reference"),
        ])
        let second = AudioInputDevice.selectable([
            microphone,
            AudioInputDevice(id: "\(SystemAudioTap.aggregateUIDPrefix)second", name: "Mimi Echo Reference"),
        ])

        XCTAssertEqual(first, [microphone])
        XCTAssertEqual(second, first)
    }

    func testBluetoothOutputDoesNotNeedSpeakerEchoReference() {
        XCTAssertFalse(AudioInputDevice.shouldUseSystemAudioReference(outputTransport: .bluetooth))
        XCTAssertTrue(AudioInputDevice.shouldUseSystemAudioReference(outputTransport: .builtIn))
        XCTAssertTrue(AudioInputDevice.shouldUseSystemAudioReference(outputTransport: .other))
    }

    func testAirPodsMuteStateZeroesSamplesUntilUnmuted() {
        let state = AudioInputMuteState()
        let samples: [Float] = [0.25, -0.5, 0.75]

        XCTAssertEqual(state.apply(to: samples), samples)
        XCTAssertTrue(state.setMuted(true))
        XCTAssertEqual(state.apply(to: samples), [0, 0, 0])
        XCTAssertTrue(state.setMuted(false))
        XCTAssertEqual(state.apply(to: samples), samples)

        state.setMuted(true)
        let afterUnmuteDuringProcessing = state.process(samples) { mutedInput in
            state.setMuted(false)
            return mutedInput
        }
        XCTAssertEqual(afterUnmuteDuringProcessing, [0, 0, 0])

        let afterMuteDuringProcessing = state.process(samples) { unmutedInput in
            state.setMuted(true)
            return unmutedInput
        }
        XCTAssertEqual(afterMuteDuringProcessing, [0, 0, 0])
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
