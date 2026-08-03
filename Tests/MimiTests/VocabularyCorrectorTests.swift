import XCTest
@testable import Mimi

final class VocabularyCorrectorTests: XCTestCase {
    func testCorrectsAliasesAndCanonicalCasing() {
        let entries = [
            VocabularyEntry(from: ["whisper flow"], to: "Wispr Flow"),
            VocabularyEntry(from: ["pie torch"], to: "PyTorch"),
            VocabularyEntry(from: [], to: "API")
        ]

        let corrected = VocabularyCorrector.correct(
            "whisper flow uses pie torch through the api.",
            entries: entries
        )

        XCTAssertEqual(corrected, "Wispr Flow uses PyTorch through the API.")
    }

    func testUsesLeftmostLongestNonOverlappingMatch() {
        let entries = [
            VocabularyEntry(from: ["whisper"], to: "Flow"),
            VocabularyEntry(from: ["whisper flow"], to: "Wispr Flow"),
            VocabularyEntry(from: ["new york"], to: "New York"),
            VocabularyEntry(from: ["york city"], to: "York City")
        ]

        XCTAssertEqual(
            VocabularyCorrector.correct("whisper flow and whisper", entries: entries),
            "Wispr Flow and Flow"
        )
        XCTAssertEqual(
            VocabularyCorrector.correct("new york city", entries: entries),
            "New York city"
        )
    }

    func testRequiresUnicodeWholeBoundaries() {
        let entries = [VocabularyEntry(from: [], to: "API")]

        let corrected = VocabularyCorrector.correct(
            "api myapi2 _api api_client api's api.",
            entries: entries
        )

        XCTAssertEqual(corrected, "API myapi2 _api api_client API's API.")
    }

    func testMatchesUnicodeNormalizationAndCaseFolding() {
        let entries = [
            VocabularyEntry(from: ["café kit"], to: "CaféKit"),
            VocabularyEntry(from: [], to: "Straße")
        ]

        let corrected = VocabularyCorrector.correct(
            "CAFE\u{301} KIT meets STRASSE.",
            entries: entries
        )

        XCTAssertEqual(corrected, "CaféKit meets Straße.")
    }

    func testSupportsTechnicalPunctuation() {
        let entries = [
            VocabularyEntry(from: ["c plus plus"], to: "C++"),
            VocabularyEntry(from: ["dot net"], to: ".NET"),
            VocabularyEntry(from: ["node dot js"], to: "Node.js")
        ]

        let corrected = VocabularyCorrector.correct(
            "c plus plus, dot net, and node dot js; not XC++17.",
            entries: entries
        )

        XCTAssertEqual(corrected, "C++, .NET, and Node.js; not XC++17.")
    }

    func testRunsOnePassAndSkipsConflictingKeys() {
        let entries = [
            VocabularyEntry(from: ["alpha"], to: "Beta"),
            VocabularyEntry(from: ["beta"], to: "Gamma"),
            VocabularyEntry(from: ["shared"], to: "First"),
            VocabularyEntry(from: ["shared"], to: "Second")
        ]

        XCTAssertEqual(
            VocabularyCorrector.correct("alpha beta shared", entries: entries),
            "Beta beta shared"
        )
    }

    func testIgnoresEmptyTargetsAndSourcesDefensively() {
        let entries = [
            VocabularyEntry(from: ["ignored"], to: "  "),
            VocabularyEntry(from: ["", "kube er net ease"], to: "Kubernetes")
        ]

        XCTAssertEqual(
            VocabularyCorrector.correct("ignored kube er net ease", entries: entries),
            "ignored Kubernetes"
        )
    }

    func testValidationRejectsEmptyAndConflictingEntries() {
        XCTAssertEqual(
            VocabularyValidator.validate([VocabularyEntry(from: [], to: "  ")]),
            .emptyTarget
        )
        XCTAssertEqual(
            VocabularyValidator.validate([VocabularyEntry(from: [""], to: "PyTorch")]),
            .emptySource
        )

        let conflict = VocabularyValidator.validate([
            VocabularyEntry(from: ["café kit"], to: "CaféKit"),
            VocabularyEntry(from: ["CAFE\u{301} KIT"], to: "Other")
        ])
        XCTAssertEqual(
            conflict,
            .conflictingPhrase("CAFE\u{301} KIT", firstTarget: "CaféKit", secondTarget: "Other")
        )
    }

    func testValidationAllowsDuplicateKeysWithinOneEntry() {
        XCTAssertNil(VocabularyValidator.validate([
            VocabularyEntry(from: ["pytorch", "PYTORCH", "pie torch"], to: "PyTorch")
        ]))
    }

    func testPreservesUntouchedTextExactly() {
        let entries = [VocabularyEntry(from: ["pie torch"], to: "PyTorch")]
        let source = "  First:\tpie torch!\nThen pie torch?  "

        XCTAssertEqual(
            VocabularyCorrector.correct(source, entries: entries),
            "  First:\tPyTorch!\nThen PyTorch?  "
        )
    }
}
