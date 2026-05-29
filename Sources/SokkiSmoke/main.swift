@preconcurrency import AppKit
@preconcurrency import AVFoundation
import Foundation
import SokkiSpeech

@main
struct SokkiSmoke {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let mode = arguments.first else {
            printUsageAndExit()
        }

        switch mode {
        case "apple-stream-file":
            guard arguments.count >= 2 else { printUsageAndExit() }
            let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            _ = try await runAppleStreamFile(url: url)
        case "end-to-end-textedit":
            guard arguments.count >= 2 else { printUsageAndExit() }
            guard arguments.contains("--allow-focus-steal") else {
                throw SmokeError.focusStealNotAllowed
            }
            let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            let backend = value(after: "--backend", in: arguments) ?? "apple"
            guard backend == "apple" else {
                throw SmokeError.unsupportedBackend(backend)
            }
            try await runTextEditEndToEnd(url: url, pressReturn: arguments.contains("--press-enter"))
        default:
            printUsageAndExit()
        }
    }

    private static func runAppleStreamFile(url: URL) async throws -> AppleSmokeSummary {
        let summary = try await transcribeAppleStreamFile(url: url, printEvents: true)
        try validateAppleStreaming(summary)
        return summary
    }

    private static func runTextEditEndToEnd(url: URL, pressReturn: Bool) async throws {
        let summary = try await transcribeAppleStreamFile(url: url, printEvents: false)
        try validateAppleStreaming(summary)

        try runAppleScript("""
        tell application "TextEdit"
            activate
            make new document
            set text of front document to ""
        end tell
        """)
        try await Task.sleep(nanoseconds: 500_000_000)

        try await paste(text: summary.finalText, pressReturn: pressReturn)
        try await Task.sleep(nanoseconds: 500_000_000)

        let documentText = try runAppleScript("""
        tell application "TextEdit"
            get text of front document
        end tell
        """)
        let documentEndsWithReturn = try runAppleScript("""
        tell application "TextEdit"
            if (text of front document) ends with return then
                return "true"
            else
                return "false"
            end if
        end tell
        """) == "true"
        _ = try? runAppleScript("""
        tell application "TextEdit"
            close front document saving no
        end tell
        """)

        print("backend=apple-speech-transcriber")
        print("target=TextEdit")
        print("press_enter=\(pressReturn)")
        print("first_partial_ms=\(summary.firstPartialMs.map(String.init) ?? "none")")
        print("partials=\(summary.partialCount)")
        print("final=\(summary.finalText)")
        print("textedit_text=\(documentText.replacingOccurrences(of: "\n", with: "\\n"))")
        print("textedit_ends_with_return=\(documentEndsWithReturn)")

        guard containsExpectedTerms(documentText) else {
            throw SmokeError.textEditDidNotReceiveTranscript(documentText)
        }
        if pressReturn, !documentEndsWithReturn {
            print("warning=textedit_return_not_observable")
        }
    }

    private static func transcribeAppleStreamFile(url: URL, printEvents: Bool) async throws -> AppleSmokeSummary {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SmokeError.fileMissing(url.path)
        }

        let recorder = SmokeRecorder(printEvents: printEvents)
        let backend = AppleSpeechTranscriberBackend(locale: Locale(identifier: "en_US"))
        let clock = ContinuousClock()
        let start = clock.now

        if printEvents {
            print("backend=apple-speech-transcriber")
            print("file=\(url.path)")
        }

        let prepareStarted = clock.now
        try await backend.prepare()
        let prepareMs = prepareStarted.duration(to: clock.now).milliseconds
        if printEvents { print("prepare_ms=\(prepareMs)") }

        try await backend.startStream { event in
            Task { await recorder.record(event: event, elapsedMs: start.duration(to: clock.now).milliseconds) }
        }

        let feedStarted = clock.now
        let feeder = Task {
            try await feedAudioFile(url: url, into: backend, chunkMilliseconds: 100)
        }
        try await feeder.value
        let feedDoneMs = start.duration(to: clock.now).milliseconds
        await recorder.setFeedDoneMs(feedDoneMs)

        let final = try await backend.finishStream()
        let totalMs = start.duration(to: clock.now).milliseconds
        let feedAndFinishMs = feedStarted.duration(to: clock.now).milliseconds
        let summary = await recorder.summary(finalText: final, totalMs: totalMs, feedAndFinishMs: feedAndFinishMs)

        if printEvents {
            print("feed_done_ms=\(feedDoneMs)")
            print("feed_and_finish_ms=\(feedAndFinishMs)")
            print("total_ms=\(totalMs)")
            print("first_partial_ms=\(summary.firstPartialMs.map(String.init) ?? "none")")
            print("partials=\(summary.partialCount)")
            print("final=\(summary.finalText)")
        }

        return summary
    }

    private static func validateAppleStreaming(_ summary: AppleSmokeSummary) throws {
        guard summary.firstPartialMs != nil else {
            throw SmokeError.noPartial
        }
        guard let firstPartialMs = summary.firstPartialMs, firstPartialMs < summary.feedDoneMs else {
            throw SmokeError.partialAfterFeedCompleted(firstPartialMs: summary.firstPartialMs, feedDoneMs: summary.feedDoneMs)
        }
        guard containsExpectedTerms(summary.finalText) else {
            throw SmokeError.unexpectedTranscript(summary.finalText)
        }
    }

    private static func feedAudioFile(url: URL, into backend: AppleSpeechTranscriberBackend, chunkMilliseconds: Int) async throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunkFrames = AVAudioFrameCount(max(1, Int(format.sampleRate * Double(chunkMilliseconds) / 1_000.0)))

        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            let framesToRead = min(chunkFrames, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRead) else {
                throw SmokeError.bufferCreationFailed
            }
            try file.read(into: buffer, frameCount: framesToRead)
            guard buffer.frameLength > 0 else { break }
            try await backend.append(buffer)
            try await Task.sleep(nanoseconds: UInt64(chunkMilliseconds) * 1_000_000)
        }
    }

    private static func paste(text: String, pressReturn: Bool) async throws {
        try await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw SmokeError.pasteboardWriteFailed
            }
        }

        try sendKey(virtualKey: 9, flags: .maskCommand) // V
        if pressReturn {
            try await Task.sleep(nanoseconds: 500_000_000)
            try sendKey(virtualKey: 36, flags: [])
        }
    }

    private static func sendKey(virtualKey: CGKeyCode, flags: CGEventFlags) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { throw SmokeError.eventSourceUnavailable }

        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    @discardableResult
    private static func runAppleScript(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = source.split(separator: "\n", omittingEmptySubsequences: false).flatMap { ["-e", String($0)] }

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let outputText = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw SmokeError.appleScriptFailed(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return outputText.trimmingCharacters(in: .newlines)
    }

    private static func containsExpectedTerms(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return ["mimi", "streaming", "smoke", "test"].filter { lowercased.contains($0) }.count >= 3
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(arguments.index(after: index)) else { return nil }
        return arguments[arguments.index(after: index)]
    }

    private static func printUsageAndExit() -> Never {
        fputs("""
        Usage:
          swift run SokkiSmoke apple-stream-file /path/to/audio.wav
          swift run SokkiSmoke end-to-end-textedit /path/to/audio.wav --backend apple --allow-focus-steal [--press-enter]
        """, stderr)
        exit(2)
    }
}

actor SmokeRecorder {
    private let printEvents: Bool
    private var firstPartialMs: Int?
    private var partialCount = 0
    private var feedDoneMs: Int?

    init(printEvents: Bool) {
        self.printEvents = printEvents
    }

    func record(event: AppleSpeechStreamEvent, elapsedMs: Int) {
        switch event {
        case .partial(let text):
            partialCount += 1
            if firstPartialMs == nil { firstPartialMs = elapsedMs }
            if printEvents { print("partial_ms=\(elapsedMs) text=\(text)") }
        case .final(let text):
            if printEvents { print("final_event_ms=\(elapsedMs) text=\(text)") }
        }
    }

    func setFeedDoneMs(_ milliseconds: Int) {
        feedDoneMs = milliseconds
    }

    func summary(finalText: String, totalMs: Int, feedAndFinishMs: Int) -> AppleSmokeSummary {
        AppleSmokeSummary(
            firstPartialMs: firstPartialMs,
            partialCount: partialCount,
            finalText: finalText,
            totalMs: totalMs,
            feedAndFinishMs: feedAndFinishMs,
            feedDoneMs: feedDoneMs ?? totalMs
        )
    }
}

struct AppleSmokeSummary {
    let firstPartialMs: Int?
    let partialCount: Int
    let finalText: String
    let totalMs: Int
    let feedAndFinishMs: Int
    let feedDoneMs: Int
}

enum SmokeError: LocalizedError {
    case fileMissing(String)
    case bufferCreationFailed
    case noPartial
    case partialAfterFeedCompleted(firstPartialMs: Int?, feedDoneMs: Int)
    case unexpectedTranscript(String)
    case unsupportedBackend(String)
    case pasteboardWriteFailed
    case eventSourceUnavailable
    case appleScriptFailed(String)
    case textEditDidNotReceiveTranscript(String)
    case textEditMissingReturn(String)
    case focusStealNotAllowed

    var errorDescription: String? {
        switch self {
        case .fileMissing(let path):
            "Audio file does not exist: \(path)"
        case .bufferCreationFailed:
            "Could not create audio buffer."
        case .noPartial:
            "Apple SpeechTranscriber did not emit any partial transcript."
        case .partialAfterFeedCompleted(let firstPartialMs, let feedDoneMs):
            "First partial arrived after file feed completed. first_partial_ms=\(firstPartialMs.map(String.init) ?? "none") feed_done_ms=\(feedDoneMs)"
        case .unexpectedTranscript(let text):
            "Transcript did not contain expected smoke-test terms: \(text)"
        case .unsupportedBackend(let backend):
            "Unsupported end-to-end backend: \(backend)"
        case .pasteboardWriteFailed:
            "Could not write transcript to pasteboard."
        case .eventSourceUnavailable:
            "Could not create keyboard event source."
        case .appleScriptFailed(let message):
            "AppleScript failed: \(message)"
        case .textEditDidNotReceiveTranscript(let text):
            "TextEdit did not receive expected transcript terms: \(text)"
        case .textEditMissingReturn(let text):
            "TextEdit text does not end with Return: \(text)"
        case .focusStealNotAllowed:
            "TextEdit smoke steals focus; rerun with --allow-focus-steal only when the laptop is idle."
        }
    }
}

private extension Duration {
    var milliseconds: Int {
        let components = components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
