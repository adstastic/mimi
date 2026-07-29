import XCTest
@testable import Mimi

final class TranscriptCleanerTests: XCTestCase {
    func testRemovesStandaloneFillersAndRepairsPunctuation() {
        let cases = [
            ("Um, I think we should ship Friday.", "I think we should ship Friday."),
            ("I, uh, think we should ship Friday.", "I think we should ship Friday."),
            ("Please send, um, the report tomorrow.", "Please send the report tomorrow."),
            ("I think we should. Ah, ship it Friday.", "I think we should. ship it Friday."),
            ("I think we should ship Friday, erm.", "I think we should ship Friday."),
            ("Um, uh, I think so.", "I think so."),
            ("Um. I think so.", "I think so."),
            ("I think. Uh. We should go.", "I think. We should go."),
            ("Ah, iPhone is ready.", "iPhone is ready."),
            ("Ah, main.swift should stay.", "main.swift should stay."),
            ("Ah, --force is risky.", "--force is risky."),
            ("For example, e.g. um, this case.", "For example, e.g. this case."),
            ("I stopped 'cause, um, it hurt.", "I stopped 'cause it hurt."),
            ("Keep  spacing. I, um, agree.", "Keep  spacing. I agree."),
            ("I um think so.", "I think so.")
        ]

        for (input, expected) in cases {
            XCTAssertEqual(TranscriptCleaner.clean(input), expected, "input: \(input)")
        }
    }

    func testPreservesQuotedAndEmbeddedFillers() {
        let cases = [
            #"The words "um" and "uh" are fillers."#,
            "The words 'um' and 'uh' are fillers.",
            "The words “ah” and “erm” are fillers.",
            "Ummagumma is an album.",
            "Say uh-huh if you agree.",
            "Email ah@example.com.",
            "Open /tmp/um/file and run --uh.",
            "Open um.txt.",
            "Battery capacity is 12 AH.",
            "Visit https://example.com/um.",
            "Use the um_value identifier.",
            "Set `um` before continuing.",
            "Keep `value um fallback` unchanged.",
            "Read $um and #uh from shell.",
            "Say uh‑huh if you agree.",
            #"He literally said "um"#,
            "He literally said “um",
            #"He said "um and then “uh”"#
        ]

        for input in cases {
            XCTAssertEqual(TranscriptCleaner.clean(input), input)
        }
    }

    func testPreservesFormattingUnrelatedToFillers() {
        let cases = [
            "First paragraph.\n\nSecond paragraph.",
            "CSV empty field: a,,b.",
            "Keep  intentional spacing."
        ]

        for input in cases {
            XCTAssertEqual(TranscriptCleaner.clean(input), input)
        }
    }

    func testTrimsWhitespaceAfterCleanup() {
        XCTAssertEqual(TranscriptCleaner.clean("  Um,   hello.  "), "hello.")
        XCTAssertEqual(TranscriptCleaner.clean("Um."), "")
        XCTAssertEqual(TranscriptCleaner.clean("Um…"), "")
    }
}
