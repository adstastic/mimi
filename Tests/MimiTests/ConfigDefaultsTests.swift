import XCTest
@testable import Mimi

final class ConfigDefaultsTests: XCTestCase {
    func testDefaultConfigUsesAppleSpeechWithSaneThresholds() {
        let config = MimiConfig.defaults

        XCTAssertEqual(config.preferredBackend, .appleSpeechTranscriber)
        XCTAssertFalse(config.ambientModeEnabled)
        XCTAssertEqual(config.dictationPasteSettings, .defaults)
        XCTAssertEqual(config.ambientPasteSettings, .defaults)
        XCTAssertTrue(config.modelDownloadEnabled)
        XCTAssertTrue(config.silenceAutoStopEnabled)
        XCTAssertTrue(config.showLiveTranscript)
        XCTAssertTrue(config.fillerCleanupEnabled)
        XCTAssertEqual(config.vocabularyEntries, [])
        XCTAssertTrue(config.voiceprintEnabled)
        XCTAssertEqual(config.voiceprintThreshold, 0.78)
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

    func testBackendCapabilitiesDescribeValidAmbientAndStopModes() {
        XCTAssertTrue(ASRBackend.appleSpeechTranscriber.capabilities.supportsAmbient)
        XCTAssertTrue(ASRBackend.appleSpeechTranscriber.capabilities.supportsSilenceDetectionMode(.audioLevel))
        XCTAssertTrue(ASRBackend.appleSpeechTranscriber.capabilities.supportsSilenceDetectionMode(.speechActivity))

        XCTAssertFalse(ASRBackend.mlxParakeetV2.capabilities.supportsAmbient)
        XCTAssertTrue(ASRBackend.mlxParakeetV2.capabilities.supportsSilenceDetectionMode(.audioLevel))
        XCTAssertFalse(ASRBackend.mlxParakeetV2.capabilities.supportsSilenceDetectionMode(.speechActivity))
    }

    func testLegacyAutomaticSilenceModeDecodesToConcreteMode() throws {
        let json = #""automatic""#

        let mode = try JSONDecoder().decode(SilenceDetectionMode.self, from: Data(json.utf8))

        XCTAssertEqual(mode, .audioLevel)
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
        XCTAssertEqual(config.dictationPasteSettings, .defaults)
        XCTAssertEqual(config.ambientPasteSettings, .defaults)
        XCTAssertNil(config.inputDeviceID)
        XCTAssertEqual(config.silenceDetectionMode, .audioLevel)
        XCTAssertTrue(config.showLiveTranscript)
        XCTAssertTrue(config.fillerCleanupEnabled)
        XCTAssertEqual(config.vocabularyEntries, [])
        XCTAssertTrue(config.voiceprintEnabled)
        XCTAssertEqual(config.voiceprintThreshold, 0.78)
    }

    func testLegacyAmbientReturnSettingMigratesToKeystroke() throws {
        let json = #"{"ambientPressEnterOnStart":true}"#

        let config = try JSONDecoder().decode(MimiConfig.self, from: Data(json.utf8))

        XCTAssertEqual(config.ambientPasteSettings.prePasteKeystroke, .returnKey)
        XCTAssertEqual(config.ambientPasteSettings.postPasteKeystroke, .returnKey)
    }

    func testStartAndEndKeystrokesMigrateToPasteBoundary() throws {
        let json = #"{"ambientStartKeystroke":{"keyCode":48,"modifierFlagsRaw":0},"ambientEndKeystroke":{"keyCode":36,"modifierFlagsRaw":0}}"#

        let config = try JSONDecoder().decode(MimiConfig.self, from: Data(json.utf8))

        XCTAssertEqual(config.ambientPasteSettings.prePasteKeystroke, MimiShortcut(keyCode: 48, modifierFlagsRaw: 0))
        XCTAssertEqual(config.ambientPasteSettings.postPasteKeystroke, .returnKey)
    }

    func testPasteSettingsPersistPerMode() {
        let suiteName = "MimiTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        var config = MimiConfig.defaults
        config.dictationPasteSettings = PasteSettings(
            prePasteKeystroke: .returnKey,
            postPasteKeystroke: nil,
            prePasteDelayMilliseconds: 325,
            postPasteDelayMilliseconds: 475
        )
        config.ambientPasteSettings = PasteSettings(
            prePasteKeystroke: nil,
            postPasteKeystroke: MimiShortcut(keyCode: 48, modifierFlagsRaw: 0),
            prePasteDelayMilliseconds: 650,
            postPasteDelayMilliseconds: 825
        )
        config.save(userDefaults: userDefaults)

        let loaded = MimiConfig.load(userDefaults: userDefaults)
        XCTAssertEqual(loaded.dictationPasteSettings, config.dictationPasteSettings)
        XCTAssertEqual(loaded.ambientPasteSettings, config.ambientPasteSettings)
    }

    func testFlatPasteSettingsMigrateToSeparateModes() throws {
        let json = #"{"ambientPrePasteKeystroke":{"keyCode":48,"modifierFlagsRaw":0},"ambientPostPasteKeystroke":null,"pressEnterAfterPaste":false,"prePasteKeystrokeDelayMilliseconds":325,"postPasteKeystrokeDelayMilliseconds":475}"#

        let config = try JSONDecoder().decode(MimiConfig.self, from: Data(json.utf8))

        XCTAssertEqual(
            config.dictationPasteSettings,
            PasteSettings(
                prePasteKeystroke: nil,
                postPasteKeystroke: nil,
                prePasteDelayMilliseconds: 325,
                postPasteDelayMilliseconds: 475
            )
        )
        XCTAssertEqual(
            config.ambientPasteSettings,
            PasteSettings(
                prePasteKeystroke: MimiShortcut(keyCode: 48, modifierFlagsRaw: 0),
                postPasteKeystroke: nil,
                prePasteDelayMilliseconds: 325,
                postPasteDelayMilliseconds: 475
            )
        )
    }

    func testVocabularyEntriesPersist() {
        let suiteName = "MimiTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        var config = MimiConfig.defaults
        config.vocabularyEntries = [
            VocabularyEntry(writtenForm: "Wispr Flow", spokenAliases: ["whisper flow"]),
            VocabularyEntry(writtenForm: "PyTorch", spokenAliases: ["pie torch"], isEnabled: false)
        ]
        config.save(userDefaults: userDefaults)

        XCTAssertEqual(MimiConfig.load(userDefaults: userDefaults).vocabularyEntries, config.vocabularyEntries)
    }

    func testFillerCleanupSettingPersists() {
        let suiteName = "MimiTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        var config = MimiConfig.defaults
        config.fillerCleanupEnabled = false
        config.save(userDefaults: userDefaults)

        XCTAssertFalse(MimiConfig.load(userDefaults: userDefaults).fillerCleanupEnabled)
    }

    func testVoiceprintThresholdIsClampedOnLoad() {
        let suiteName = "MimiTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        var config = MimiConfig.defaults
        config.voiceprintThreshold = 1.5
        config.save(userDefaults: userDefaults)

        XCTAssertEqual(MimiConfig.load(userDefaults: userDefaults).voiceprintThreshold, 0.95)
    }
}
