import XCTest
@testable import Mimi

final class VocabularyCorrectorTests: XCTestCase {
    func testCorrectsAliasesAndCanonicalCasing() {
        let entries = [
            VocabularyEntry(writtenForm: "Wispr Flow", spokenAliases: ["whisper flow"]),
            VocabularyEntry(writtenForm: "PyTorch", spokenAliases: ["pie torch"]),
            VocabularyEntry(writtenForm: "API")
        ]

        let corrected = VocabularyCorrector.correct(
            "whisper flow uses pie torch through the api.",
            entries: entries
        )

        XCTAssertEqual(corrected, "Wispr Flow uses PyTorch through the API.")
    }

    func testUsesLeftmostLongestNonOverlappingMatch() {
        let entries = [
            VocabularyEntry(writtenForm: "Flow", spokenAliases: ["whisper"]),
            VocabularyEntry(writtenForm: "Wispr Flow", spokenAliases: ["whisper flow"]),
            VocabularyEntry(writtenForm: "New York", spokenAliases: ["new york"]),
            VocabularyEntry(writtenForm: "York City", spokenAliases: ["york city"])
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
        let entries = [VocabularyEntry(writtenForm: "API")]

        let corrected = VocabularyCorrector.correct(
            "api myapi2 _api api_client api's api.",
            entries: entries
        )

        XCTAssertEqual(corrected, "API myapi2 _api api_client API's API.")
    }

    func testMatchesUnicodeNormalizationAndCaseFolding() {
        let entries = [
            VocabularyEntry(writtenForm: "CaféKit", spokenAliases: ["café kit"]),
            VocabularyEntry(writtenForm: "Straße")
        ]

        let corrected = VocabularyCorrector.correct(
            "CAFE\u{301} KIT meets STRASSE.",
            entries: entries
        )

        XCTAssertEqual(corrected, "CaféKit meets Straße.")
    }

    func testSupportsTechnicalPunctuation() {
        let entries = [
            VocabularyEntry(writtenForm: "C++", spokenAliases: ["c plus plus"]),
            VocabularyEntry(writtenForm: ".NET", spokenAliases: ["dot net"]),
            VocabularyEntry(writtenForm: "Node.js", spokenAliases: ["node dot js"])
        ]

        let corrected = VocabularyCorrector.correct(
            "c plus plus, dot net, and node dot js; not XC++17.",
            entries: entries
        )

        XCTAssertEqual(corrected, "C++, .NET, and Node.js; not XC++17.")
    }

    func testRunsOnePassAndSkipsConflictingKeys() {
        let entries = [
            VocabularyEntry(writtenForm: "Beta", spokenAliases: ["alpha"]),
            VocabularyEntry(writtenForm: "Gamma", spokenAliases: ["beta"]),
            VocabularyEntry(writtenForm: "First", spokenAliases: ["shared"]),
            VocabularyEntry(writtenForm: "Second", spokenAliases: ["shared"])
        ]

        XCTAssertEqual(
            VocabularyCorrector.correct("alpha beta shared", entries: entries),
            "Beta beta shared"
        )
    }

    func testIgnoresDisabledAndEmptyEntries() {
        let entries = [
            VocabularyEntry(writtenForm: "PyTorch", spokenAliases: ["pie torch"], isEnabled: false),
            VocabularyEntry(writtenForm: "  ", spokenAliases: ["ignored"]),
            VocabularyEntry(writtenForm: "Kubernetes", spokenAliases: ["", "kube er net ease"])
        ]

        XCTAssertEqual(
            VocabularyCorrector.correct("pie torch ignored kube er net ease", entries: entries),
            "pie torch ignored Kubernetes"
        )
    }

    func testPreservesUntouchedTextExactly() {
        let entries = [VocabularyEntry(writtenForm: "PyTorch", spokenAliases: ["pie torch"])]
        let source = "  First:\tpie torch!\nThen pie torch?  "

        XCTAssertEqual(
            VocabularyCorrector.correct(source, entries: entries),
            "  First:\tPyTorch!\nThen PyTorch?  "
        )
    }
}
