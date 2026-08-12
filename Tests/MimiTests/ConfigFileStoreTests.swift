import Foundation
import XCTest
@testable import Mimi

final class ConfigFileStoreTests: XCTestCase {
    func testMissingFileMigratesLegacyConfigAndVocabulary() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let legacyData = Data(#"{"vocabularyEntries":[{"id":"00000000-0000-0000-0000-000000000001","writtenForm":"nima","spokenAliases":["nema","neema"],"isEnabled":true},{"id":"00000000-0000-0000-0000-000000000002","writtenForm":"ignored","spokenAliases":["disabled"],"isEnabled":false}]}"#.utf8)
        fixture.defaults.set(legacyData, forKey: "MimiConfig.v1")

        let store = MimiConfigFileStore(
            fileURL: fixture.configURL,
            legacyDefaults: fixture.defaults
        )
        let loaded = store.loadInitial()

        XCTAssertTrue(store.didCreateInitialConfig)
        XCTAssertEqual(
            loaded.vocabulary,
            [VocabularyEntry(from: ["nema", "neema"], to: "nima")]
        )
        XCTAssertTrue(store.isWritable)
        XCTAssertNil(store.errorDescription)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.configURL)) as? [String: Any]
        )
        let vocabulary = try XCTUnwrap(object["vocabulary"] as? [[String: Any]])
        XCTAssertEqual(vocabulary.count, 1)
        XCTAssertEqual(vocabulary[0]["from"] as? [String], ["nema", "neema"])
        XCTAssertEqual(vocabulary[0]["to"] as? String, "nima")
        XCTAssertNil(vocabulary[0]["id"])
        XCTAssertNil(vocabulary[0]["isEnabled"])
        XCTAssertNil(object["vocabularyEntries"])
        XCTAssertNil(object["hotkeyKeyCode"])
        XCTAssertNil(object["ambientStartKeystroke"])
        XCTAssertNotNil(object["correctionShortcut"])
        let text = try String(contentsOf: fixture.configURL, encoding: .utf8)
        XCTAssertTrue(text.contains(#"    { "from" : ["nema", "neema"], "to" : "nima" }"#))
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.configURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testExistingFileDoesNotCountAsInitialConfigCreation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = MimiConfigFileStore(fileURL: fixture.configURL, legacyDefaults: fixture.defaults).loadInitial()

        let store = MimiConfigFileStore(fileURL: fixture.configURL, legacyDefaults: fixture.defaults)
        _ = store.loadInitial()

        XCTAssertFalse(store.didCreateInitialConfig)
    }

    func testExternalManualEditBlocksWritesUntilReload() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = MimiConfigFileStore(
            fileURL: fixture.configURL,
            legacyDefaults: fixture.defaults
        )
        _ = store.loadInitial()
        let manualData = Data(#"{"vocabulary":[]}"#.utf8)
        try manualData.write(to: fixture.configURL, options: .atomic)

        XCTAssertThrowsError(try store.save(.defaults))
        XCTAssertFalse(store.isWritable)
        XCTAssertEqual(try Data(contentsOf: fixture.configURL), manualData)

        _ = try store.reload()
        XCTAssertTrue(store.isWritable)
        try store.save(.defaults)
    }

    func testInvalidFileStaysUntouchedUntilReloadSucceeds() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var lastGood = MimiConfig.defaults
        lastGood.vocabulary = [VocabularyEntry(from: ["Shimi"], to: "mimi")]
        lastGood.save(userDefaults: fixture.defaults)
        let invalidData = Data(#"{"preferredBackend": "broken"}"#.utf8)
        try invalidData.write(to: fixture.configURL)

        let store = MimiConfigFileStore(
            fileURL: fixture.configURL,
            legacyDefaults: fixture.defaults
        )
        let loaded = store.loadInitial()

        XCTAssertEqual(loaded.vocabulary, lastGood.vocabulary)
        XCTAssertFalse(store.isWritable)
        XCTAssertNotNil(store.errorDescription)
        XCTAssertThrowsError(try store.save(.defaults))
        XCTAssertEqual(try Data(contentsOf: fixture.configURL), invalidData)

        try Data(#"{"vocabularyEntries":[{"id":"00000000-0000-0000-0000-000000000001","writtenForm":"PyTorch","spokenAliases":["pie torch"],"isEnabled":true}]}"#.utf8)
            .write(to: fixture.configURL, options: .atomic)
        let reloaded = try store.reload()

        XCTAssertTrue(store.isWritable)
        XCTAssertNil(store.errorDescription)
        XCTAssertEqual(reloaded.vocabulary, [VocabularyEntry(from: ["pie torch"], to: "PyTorch")])
        XCTAssertEqual(reloaded.preferredBackend, MimiConfig.defaults.preferredBackend)
        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.configURL)) as? [String: Any]
        )
        XCTAssertNotNil(migratedObject["vocabulary"])
        XCTAssertNil(migratedObject["vocabularyEntries"])
    }

    func testWrongTypesRangesAndUnknownKeysAreRejectedWithoutOverwrite() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = MimiConfigFileStore(
            fileURL: fixture.configURL,
            legacyDefaults: fixture.defaults
        )
        _ = store.loadInitial()

        for invalid in [
            #"{"silenceDurationMilliseconds":"fast"}"#,
            #"{"silenceDetectionMode":"mystery"}"#,
            #"{"dictationShortcut":{"keyCode":-1,"modifierFlagsRaw":0}}"#,
            #"{"correctionShortcut":{"keyCode":128,"modifierFlagsRaw":0}}"#,
            #"{"correctionShortcut":{"keyCode":8,"modifierFlagsRaw":1}}"#,
            #"{"voiceprintThreshold":9}"#,
            #"{"vocabulary":[],"typoSetting":true}"#,
            #"{"vocabulary":[{"from":"Jason","to":"JSON"}]}"#,
            #"{"vocabulary":[{"from":["Jason"],"to":"JSON","id":"legacy"}]}"#,
            #"{"vocabulary":[{"from":[""],"to":"JSON"}]}"#,
            #"{"vocabulary":[],"vocabularyEntries":[]}"#,
            #"{"dictationPasteSettings":{"unexpected":true}}"#,
            #"{"dictationPasteSettings":{"prePasteKeystroke":{"keyCode":36,"modifierFlagsRaw":0,"unexpected":true}}}"#,
            #"{"pastePresets":[{"name":"A","paste":{},"unexpected":true}]}"#,
            #"{"pastePresets":[{"name":"A","paste":{"unexpected":true}}]}"#,
            #"{"pastePresets":[{"name":" ","paste":{}}]}"#,
            #"{"pastePresets":[{"name":"Manual","paste":{}}]}"#,
            #"{"pastePresets":[{"name":"A","paste":{}},{"name":"A","paste":{}}]}"#,
            #"{"pastePresets":[{"name":"A","paste":{"postPasteDelayMilliseconds":9000}}]}"#,
            #"{"activePastePresetName":"Missing","pastePresets":[]}"#
        ] {
            let data = Data(invalid.utf8)
            try data.write(to: fixture.configURL, options: .atomic)
            XCTAssertThrowsError(try store.reload())
            XCTAssertFalse(store.isWritable)
            XCTAssertThrowsError(try store.save(.defaults))
            XCTAssertEqual(try Data(contentsOf: fixture.configURL), data)
        }
    }
}

private struct Fixture {
    let directory: URL
    let configURL: URL
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimiTests-\(UUID().uuidString)", isDirectory: true)
        configURL = directory.appendingPathComponent("config.json")
        suiteName = "MimiTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
