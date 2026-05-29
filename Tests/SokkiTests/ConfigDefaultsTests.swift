import XCTest
@testable import Sokki

final class ConfigDefaultsTests: XCTestCase {
    func testDefaultConfigIsLocalNoTelemetryAppleSpeechWithSaneThresholds() {
        let config = SokkiConfig.defaults

        XCTAssertEqual(config.preferredBackend, .appleSpeechTranscriber)
        XCTAssertFalse(config.ambientModeEnabled)
        XCTAssertFalse(config.telemetryEnabled)
        XCTAssertFalse(config.cloudTranscriptionEnabled)
        XCTAssertTrue(config.modelDownloadEnabled)
        XCTAssertTrue(config.silenceAutoStopEnabled)
        XCTAssertTrue(config.pressEnterAfterPaste)
        XCTAssertEqual(config.hotkeyKeyCode, 54)
        XCTAssertTrue(config.isLocalOnlyNoTelemetry)

        XCTAssertEqual(config.silenceThresholdDBFS, -50)
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

    func testLoadMigratesOldMlxAndThresholdDefaultsPersistently() {
        let suiteName = "SokkiTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        var oldConfig = SokkiConfig.defaults
        oldConfig.preferredBackend = .mlxParakeetV2
        oldConfig.silenceThresholdDBFS = -38
        oldConfig.save(userDefaults: userDefaults)

        let firstLoad = SokkiConfig.load(userDefaults: userDefaults)
        XCTAssertEqual(firstLoad.preferredBackend, .appleSpeechTranscriber)
        XCTAssertEqual(firstLoad.silenceThresholdDBFS, -50)

        let secondLoad = SokkiConfig.load(userDefaults: userDefaults)
        XCTAssertEqual(secondLoad.preferredBackend, .appleSpeechTranscriber)
        XCTAssertEqual(secondLoad.silenceThresholdDBFS, -50)
    }
}
