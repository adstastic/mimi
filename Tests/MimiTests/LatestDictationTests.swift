import Foundation
import XCTest
@testable import Mimi

@MainActor
final class LatestDictationTests: XCTestCase {
    func testLatestDictationReplacesAudioAndDeletesOwnedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimiTests-\(UUID().uuidString)", isDirectory: true)
        let retainedURL = directory.appendingPathComponent("latest.wav")
        let firstSource = directory.appendingPathComponent("first-source.wav")
        let secondSource = directory.appendingPathComponent("second-source.wav")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)

        let store = HistoryStore(audioStorageURL: retainedURL)
        store.record(
            sourceText: "pie torch",
            text: "pie torch",
            backend: .appleSpeechTranscriber,
            audioURL: firstSource
        )

        XCTAssertEqual(store.latest?.sourceText, "pie torch")
        XCTAssertEqual(store.latest?.text, "pie torch")
        XCTAssertEqual(store.latest?.backend, .appleSpeechTranscriber)
        XCTAssertEqual(store.latest?.audioURL, retainedURL)
        XCTAssertEqual(try Data(contentsOf: retainedURL), Data("first".utf8))
        let firstID = try XCTUnwrap(store.latest?.id)

        store.record(
            sourceText: "whisper flow",
            text: "Wispr Flow",
            backend: .appleSpeechTranscriber,
            audioURL: secondSource
        )

        XCTAssertNotNil(store.latest)
        XCTAssertEqual(store.latest?.sourceText, "whisper flow")
        XCTAssertEqual(store.latest?.text, "Wispr Flow")
        XCTAssertEqual(try Data(contentsOf: retainedURL), Data("second".utf8))
        let secondID = try XCTUnwrap(store.latest?.id)

        XCTAssertNil(store.updateLastTranscript(id: firstID, text: "stale correction"))
        XCTAssertEqual(
            store.updateLastTranscript(id: secondID, text: "  Wispr Flow works.  "),
            "Wispr Flow works."
        )
        XCTAssertEqual(store.lastTranscript, "Wispr Flow works.")

        store.clear()
        XCTAssertNil(store.latest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedURL.path))
    }

    func testStaleTemporaryAudioSweepRemovesOnlyMimiCaptureDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimiTests-\(UUID().uuidString)", isDirectory: true)
        let rawDirectory = directory.appendingPathComponent("mimi-", isDirectory: true)
        let ownerDirectory = directory.appendingPathComponent("mimi-owner-", isDirectory: true)
        let unrelatedURL = directory.appendingPathComponent("keep.txt")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ownerDirectory, withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: rawDirectory.appendingPathComponent("raw.wav"))
        try Data("owner".utf8).write(to: ownerDirectory.appendingPathComponent("owner.wav"))
        try Data("keep".utf8).write(to: unrelatedURL)

        TemporaryAudioFiles.removeStaleFiles(in: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: rawDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownerDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    func testCorrectionSuggestionFindsChangedSpan() {
        XCTAssertEqual(
            VocabularyCorrectionSuggestion.infer(
                source: "We use pie torch for training.",
                corrected: "We use PyTorch for training."
            ),
            VocabularyCorrectionSuggestion(heard: "pie torch", written: "PyTorch")
        )
        XCTAssertNil(VocabularyCorrectionSuggestion.infer(source: "No change", corrected: "No change"))
        XCTAssertEqual(
            VocabularyCorrectionSuggestion.inferAll(
                source: "We use pie torch. Then whisper flow handles notes.",
                corrected: "We use PyTorch. Then Wispr Flow handles notes."
            ),
            [
                VocabularyCorrectionSuggestion(heard: "pie torch", written: "PyTorch"),
                VocabularyCorrectionSuggestion(heard: "whisper flow", written: "Wispr Flow")
            ]
        )
        XCTAssertEqual(
            VocabularyCorrectionSuggestion.inferAll(
                source: "Use PyTorch today.",
                corrected: "Use PyTorch today please!"
            ),
            []
        )
    }

    func testCorrectionSuggestionKeepsReplacementWhenPunctuationAlsoChanges() {
        XCTAssertEqual(
            VocabularyCorrectionSuggestion.inferAll(
                source: "pie torch works.",
                corrected: "PyTorch works!"
            ),
            [VocabularyCorrectionSuggestion(heard: "pie torch", written: "PyTorch")]
        )
        XCTAssertEqual(
            VocabularyCorrectionSuggestion.inferAll(
                source: "node dot js",
                corrected: "Node.js"
            ),
            [VocabularyCorrectionSuggestion(heard: "node dot js", written: "Node.js")]
        )
    }

    func testCorrectionSuggestionRejectsWholeSentenceReplacement() {
        XCTAssertTrue(
            VocabularyCorrectionSuggestion.inferAll(
                source: "Go home.",
                corrected: "Leave now."
            ).isEmpty
        )
        XCTAssertTrue(
            VocabularyCorrectionSuggestion.inferAll(
                source: "Okay. Go home. Then wait.",
                corrected: "Okay. Leave now. Then wait."
            ).isEmpty
        )
    }

    func testCorrectionSuggestionMustOccurInRawASRSource() {
        XCTAssertTrue(VocabularyCorrector.contains(phrase: "pie torch", in: "Shimi uses pie torch"))
        XCTAssertFalse(VocabularyCorrector.contains(phrase: "mimi", in: "Shimi uses pie torch"))
    }

    func testAddingCorrectionMergesSourceIntoExistingTarget() throws {
        let original = [VocabularyEntry(from: ["pi torch"], to: "PyTorch")]
        let updated = try VocabularyEntryUpdater.addingCorrection(
            heard: "pie torch",
            written: "PyTorch",
            to: original
        )

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].from, ["pi torch", "pie torch"])
    }

    func testAddingMultipleCorrectionsCreatesSeparateRules() throws {
        let corrections = VocabularyCorrectionSuggestion.inferAll(
            source: "We use pie torch. Then whisper flow handles notes.",
            corrected: "We use PyTorch. Then Wispr Flow handles notes."
        )

        let updated = try VocabularyEntryUpdater.addingCorrections(corrections, to: [])

        XCTAssertEqual(updated.map(\.to), ["PyTorch", "Wispr Flow"])
        XCTAssertEqual(updated.map(\.from), [["pie torch"], ["whisper flow"]])
    }

    func testAddingMultipleCorrectionsReplaceConflictingExistingRules() throws {
        let original = [
            VocabularyEntry(from: ["get hub"], to: "Git Hub"),
            VocabularyEntry(from: ["herder"], to: "Herder")
        ]
        let corrections = [
            VocabularyCorrectionSuggestion(heard: "Git Hub", written: "GitHub"),
            VocabularyCorrectionSuggestion(heard: "Herder", written: "Herdr")
        ]

        let updated = try VocabularyEntryUpdater.addingCorrections(corrections, to: original)

        XCTAssertEqual(updated, [
            VocabularyEntry(from: ["get hub", "Git Hub"], to: "GitHub"),
            VocabularyEntry(from: ["herder"], to: "Herdr")
        ])
    }
}
