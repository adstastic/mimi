import XCTest
@testable import Mimi

final class PastePresetTests: XCTestCase {
    func testDefaultsStartManualAndKeepPerModeSettings() {
        let config = MimiConfig.defaults

        XCTAssertNil(config.activePastePresetName)
        XCTAssertEqual(config.activePastePresetLabel, PastePreset.manualName)
        XCTAssertEqual(config.pasteSettings(isAmbient: false), config.dictationPasteSettings)
        XCTAssertEqual(config.pasteSettings(isAmbient: true), config.ambientPasteSettings)
        XCTAssertEqual(config.pastePresetShortcut, .pastePresetDefault)
    }

    func testActivePresetOverridesBothModes() {
        var config = MimiConfig.defaults
        config.activePastePresetName = "TUICR"

        let expected = PasteSettings.preset(pre: MimiShortcut(keyCode: 8, modifierFlagsRaw: 0), post: .returnKey)
        XCTAssertEqual(config.pasteSettings(isAmbient: false), expected)
        XCTAssertEqual(config.pasteSettings(isAmbient: true), expected)
    }

    func testCycleWalksManualThenPresetsAndWrapsBack() {
        var config = MimiConfig.defaults
        var labels: [String] = []
        for _ in 0 ... config.pastePresets.count {
            config.cyclePastePreset()
            labels.append(config.activePastePresetLabel)
        }

        XCTAssertEqual(labels, ["Terminal agent", "RevDiff", "TUICR", PastePreset.manualName])
    }

    func testNormalizeClearsDanglingActivePresetName() {
        var config = MimiConfig.defaults
        config.activePastePresetName = "Deleted preset"

        XCTAssertTrue(config.normalizeForBackend())
        XCTAssertNil(config.activePastePresetName)
    }

    func testPresetsPersist() {
        let suiteName = "MimiTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        var config = MimiConfig.defaults
        config.pastePresets.append(PastePreset(name: "Notes", paste: .preset(pre: nil, post: nil)))
        config.activePastePresetName = "Notes"
        config.pastePresetShortcut = MimiShortcut(keyCode: 15, modifierFlagsRaw: 0)
        config.save(userDefaults: userDefaults)

        let loaded = MimiConfig.load(userDefaults: userDefaults)
        XCTAssertEqual(loaded.pastePresets, config.pastePresets)
        XCTAssertEqual(loaded.activePastePresetName, "Notes")
        XCTAssertEqual(loaded.pastePresetShortcut, config.pastePresetShortcut)
    }

    func testKeystrokeSummaryDescribesOrder() {
        XCTAssertEqual(
            PasteSettings.preset(pre: MimiShortcut(keyCode: 8, modifierFlagsRaw: 0), post: .returnKey).keystrokeSummary,
            "C → paste → Return"
        )
        XCTAssertEqual(PasteSettings.preset(pre: nil, post: nil).keystrokeSummary, "paste")
    }
}
