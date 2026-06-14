import XCTest
@testable import Mimi

final class ConfigDefaultsTests: XCTestCase {
    func testDefaultConfigUsesAppleSpeechWithSaneThresholds() {
        let config = MimiConfig.defaults

        XCTAssertEqual(config.preferredBackend, .appleSpeechTranscriber)
        XCTAssertFalse(config.ambientModeEnabled)
        XCTAssertTrue(config.modelDownloadEnabled)
        XCTAssertTrue(config.silenceAutoStopEnabled)
        XCTAssertTrue(config.pressEnterAfterPaste)
        XCTAssertEqual(config.hotkeyKeyCode, 54)
        XCTAssertEqual(config.dictationShortcut, .rightCommand)
        XCTAssertEqual(config.ambientToggleShortcut, .ambientToggleDefault)
        XCTAssertNil(config.inputDeviceID)
        XCTAssertEqual(config.silenceDetectionMode, .audioLevel)

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
        let suiteName = "MimiTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        var oldConfig = MimiConfig.defaults
        oldConfig.preferredBackend = .mlxParakeetV2
        oldConfig.silenceThresholdDBFS = -38
        oldConfig.save(userDefaults: userDefaults)

        let firstLoad = MimiConfig.load(userDefaults: userDefaults)
        XCTAssertEqual(firstLoad.preferredBackend, .appleSpeechTranscriber)
        XCTAssertEqual(firstLoad.silenceThresholdDBFS, -50)

        let secondLoad = MimiConfig.load(userDefaults: userDefaults)
        XCTAssertEqual(secondLoad.preferredBackend, .appleSpeechTranscriber)
        XCTAssertEqual(secondLoad.silenceThresholdDBFS, -50)
    }

    func testParakeetForcesRmsAndDisablesAmbient() {
        var config = MimiConfig.defaults
        config.preferredBackend = .mlxParakeetV2
        config.ambientModeEnabled = true
        config.silenceDetectionMode = .speechActivity

        XCTAssertTrue(config.normalizeForBackend())
        XCTAssertFalse(config.ambientModeEnabled)
        XCTAssertEqual(config.silenceDetectionMode, .audioLevel)
    }

    func testLoadMigratesLegacyHotkeyToDictationShortcut() throws {
        let suiteName = "MimiTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let json = """
        {
          "preferredBackend": "appleSpeechTranscriber",
          "silenceAutoStopEnabled": true,
          "silenceThresholdDBFS": -50,
          "silenceDurationMilliseconds": 2000,
          "minUtteranceMilliseconds": 350,
          "preRollMilliseconds": 700,
          "tapThresholdMilliseconds": 220,
          "hotkeyKeyCode": 54,
          "ambientModeEnabled": false,
          "pressEnterAfterPaste": true,
          "postPasteEnterDelayMilliseconds": 150,
          "modelDownloadEnabled": true
        }
        """
        userDefaults.set(Data(json.utf8), forKey: "MimiConfig.v1")
        userDefaults.set(true, forKey: "MimiConfig.appleSpeechDefault.v1")

        let config = MimiConfig.load(userDefaults: userDefaults)

        XCTAssertEqual(config.dictationShortcut, .rightCommand)
        XCTAssertEqual(config.ambientToggleShortcut, .ambientToggleDefault)
        XCTAssertNil(config.inputDeviceID)
        XCTAssertEqual(config.silenceDetectionMode, .audioLevel)
    }
}
