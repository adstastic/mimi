import Foundation
import XCTest
@testable import Mimi

final class ConfigFileStoreTests: XCTestCase {
    func testMissingFileMigratesLegacyConfigAndVocabulary() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var legacy = MimiConfig.defaults
        legacy.vocabularyEntries = [
            VocabularyEntry(writtenForm: "JSON", spokenAliases: ["Jason"]),
            VocabularyEntry(writtenForm: "config", spokenAliases: ["convict"])
        ]
        legacy.save(userDefaults: fixture.defaults)

        let store = MimiConfigFileStore(
            fileURL: fixture.configURL,
            legacyDefaults: fixture.defaults
        )
        let loaded = store.loadInitial()

        XCTAssertEqual(loaded.vocabularyEntries, legacy.vocabularyEntries)
        XCTAssertTrue(store.isWritable)
        XCTAssertNil(store.errorDescription)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.configURL)) as? [String: Any]
        )
        XCTAssertEqual((object["vocabularyEntries"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(object["hotkeyKeyCode"])
        XCTAssertNil(object["ambientStartKeystroke"])
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.configURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testExternalManualEditBlocksWritesUntilReload() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = MimiConfigFileStore(
            fileURL: fixture.configURL,
            legacyDefaults: fixture.defaults
        )
        _ = store.loadInitial()
        let manualData = Data(#"{"vocabularyEntries":[]}"#.utf8)
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
        lastGood.vocabularyEntries = [VocabularyEntry(writtenForm: "mimi", spokenAliases: ["Shimi"])]
        lastGood.save(userDefaults: fixture.defaults)
        let invalidData = Data(#"{"preferredBackend": "broken"}"#.utf8)
        try invalidData.write(to: fixture.configURL)

        let store = MimiConfigFileStore(
            fileURL: fixture.configURL,
            legacyDefaults: fixture.defaults
        )
        let loaded = store.loadInitial()

        XCTAssertEqual(loaded.vocabularyEntries, lastGood.vocabularyEntries)
        XCTAssertFalse(store.isWritable)
        XCTAssertNotNil(store.errorDescription)
        XCTAssertThrowsError(try store.save(.defaults))
        XCTAssertEqual(try Data(contentsOf: fixture.configURL), invalidData)

        try Data(#"{"vocabularyEntries":[{"id":"00000000-0000-0000-0000-000000000001","writtenForm":"PyTorch","spokenAliases":["pie torch"],"isEnabled":true}]}"#.utf8)
            .write(to: fixture.configURL, options: .atomic)
        let reloaded = try store.reload()

        XCTAssertTrue(store.isWritable)
        XCTAssertNil(store.errorDescription)
        XCTAssertEqual(reloaded.vocabularyEntries.map(\.writtenForm), ["PyTorch"])
        XCTAssertEqual(reloaded.preferredBackend, MimiConfig.defaults.preferredBackend)
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
            #"{"voiceprintThreshold":9}"#,
            #"{"vocabularyEntries":[],"typoSetting":true}"#,
            #"{"dictationPasteSettings":{"unexpected":true}}"#,
            #"{"dictationPasteSettings":{"prePasteKeystroke":{"keyCode":36,"modifierFlagsRaw":0,"unexpected":true}}}"#
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
