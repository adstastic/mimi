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
}
