import XCTest
@testable import Sokki

final class ConfigDefaultsTests: XCTestCase {
    func testDefaultConfigUsesAppleSpeechWithSaneThresholds() {
        let config = SokkiConfig.defaults

        XCTAssertEqual(config.preferredBackend, .appleSpeechTranscriber)
        XCTAssertFalse(config.ambientModeEnabled)
        XCTAssertTrue(config.modelDownloadEnabled)
        XCTAssertTrue(config.silenceAutoStopEnabled)
        XCTAssertTrue(config.pressEnterAfterPaste)
        XCTAssertEqual(config.hotkeyKeyCode, 54)
        XCTAssertEqual(config.dictationShortcut, .rightCommand)
        XCTAssertEqual(config.ambientToggleShortcut, .ambientToggleDefault)

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

    func testLoadMigratesLegacyHotkeyToDictationShortcut() throws {
        let suiteName = "SokkiTests.\(UUID().uuidString)"
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
        userDefaults.set(Data(json.utf8), forKey: "SokkiConfig.v4")
        userDefaults.set(true, forKey: "SokkiConfig.appleStreamingDefault.v1")

        let config = SokkiConfig.load(userDefaults: userDefaults)

        XCTAssertEqual(config.dictationShortcut, .rightCommand)
        XCTAssertEqual(config.ambientToggleShortcut, .ambientToggleDefault)
    }
}
