import XCTest
@testable import Sokki

final class ConfigDefaultsTests: XCTestCase {
    func testDefaultConfigIsLocalNoTelemetryMlxParakeetV2WithSaneThresholds() {
        let config = SokkiConfig.defaults

        XCTAssertEqual(config.preferredBackend, .mlxParakeetV2)
        XCTAssertFalse(config.ambientModeEnabled)
        XCTAssertFalse(config.telemetryEnabled)
        XCTAssertFalse(config.cloudTranscriptionEnabled)
        XCTAssertTrue(config.modelDownloadEnabled)
        XCTAssertEqual(config.autoEnterMode, .off)
        XCTAssertEqual(config.hotkeyKeyCode, 61)
        XCTAssertTrue(config.isLocalOnlyNoTelemetry)

        XCTAssertLessThan(config.silenceThresholdDBFS, 0)
        XCTAssertGreaterThan(config.silenceThresholdDBFS, -80)
        XCTAssertLessThanOrEqual(config.silenceThresholdDBFS, -20)
        XCTAssertGreaterThanOrEqual(config.silenceDurationMilliseconds, 250)
        XCTAssertLessThanOrEqual(config.silenceDurationMilliseconds, 3_000)
        XCTAssertGreaterThanOrEqual(config.minUtteranceMilliseconds, 200)
        XCTAssertLessThanOrEqual(config.minUtteranceMilliseconds, 1_000)
        XCTAssertGreaterThanOrEqual(config.preRollMilliseconds, 250)
        XCTAssertLessThanOrEqual(config.preRollMilliseconds, 1_500)
        XCTAssertGreaterThanOrEqual(config.tapThresholdMilliseconds, 120)
        XCTAssertLessThanOrEqual(config.tapThresholdMilliseconds, 500)
    }
}
