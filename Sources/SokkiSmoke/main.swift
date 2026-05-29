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
            try await runAppleStreamFile(url: url)
        default:
            printUsageAndExit()
        }
    }

    private static func runAppleStreamFile(url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SmokeError.fileMissing(url.path)
        }

        let recorder = SmokeRecorder()
        let backend = AppleSpeechTranscriberBackend(locale: Locale(identifier: "en_US"))
        let clock = ContinuousClock()
        let start = clock.now

        print("backend=apple-speech-transcriber")
        print("file=\(url.path)")

        let prepareStarted = clock.now
        try await backend.prepare()
        let prepareMs = prepareStarted.duration(to: clock.now).milliseconds
        print("prepare_ms=\(prepareMs)")

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
        let feedMs = feedStarted.duration(to: clock.now).milliseconds
        let summary = await recorder.summary(finalText: final, totalMs: totalMs, feedMs: feedMs)

        print("feed_done_ms=\(feedDoneMs)")
        print("feed_and_finish_ms=\(feedMs)")
        print("total_ms=\(totalMs)")
        print("first_partial_ms=\(summary.firstPartialMs.map(String.init) ?? "none")")
        print("partials=\(summary.partialCount)")
        print("final=\(summary.finalText)")

        guard summary.firstPartialMs != nil else {
            throw SmokeError.noPartial
        }
        guard let firstPartialMs = summary.firstPartialMs, firstPartialMs < feedDoneMs else {
            throw SmokeError.partialAfterFeedCompleted(firstPartialMs: summary.firstPartialMs, feedDoneMs: feedDoneMs)
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

    private static func containsExpectedTerms(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return ["sokki", "streaming", "smoke", "test"].filter { lowercased.contains($0) }.count >= 3
    }

    private static func printUsageAndExit() -> Never {
        fputs("Usage: swift run SokkiSmoke apple-stream-file /path/to/audio.wav\n", stderr)
        exit(2)
    }
}

actor SmokeRecorder {
    private var firstPartialMs: Int?
    private var partialCount = 0
    private var feedDoneMs: Int?

    func record(event: AppleSpeechStreamEvent, elapsedMs: Int) {
        switch event {
        case .partial(let text):
            partialCount += 1
            if firstPartialMs == nil { firstPartialMs = elapsedMs }
            print("partial_ms=\(elapsedMs) text=\(text)")
        case .final(let text):
            print("final_event_ms=\(elapsedMs) text=\(text)")
        }
    }

    func setFeedDoneMs(_ milliseconds: Int) {
        feedDoneMs = milliseconds
    }

    func summary(finalText: String, totalMs: Int, feedMs: Int) -> SmokeSummary {
        SmokeSummary(
            firstPartialMs: firstPartialMs,
            partialCount: partialCount,
            finalText: finalText,
            totalMs: totalMs,
            feedMs: feedMs,
            feedDoneMs: feedDoneMs
        )
    }
}

struct SmokeSummary {
    let firstPartialMs: Int?
    let partialCount: Int
    let finalText: String
    let totalMs: Int
    let feedMs: Int
    let feedDoneMs: Int?
}

enum SmokeError: LocalizedError {
    case fileMissing(String)
    case bufferCreationFailed
    case noPartial
    case partialAfterFeedCompleted(firstPartialMs: Int?, feedDoneMs: Int)
    case unexpectedTranscript(String)

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
        }
    }
}

private extension Duration {
    var milliseconds: Int {
        let components = components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
