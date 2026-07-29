@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Speech

public enum AppleSpeechStreamEvent: Sendable, Equatable {
    case partial(String)
    case final(String)
}

public enum AppleSpeechTranscriberError: LocalizedError, Sendable {
    case unavailable
    case unsupportedLocale(String)
    case assetUnsupported
    case assetNotInstalled(String)
    case noCompatibleAudioFormat
    case streamAlreadyActive
    case streamNotActive
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Apple SpeechTranscriber is not available on this Mac."
        case .unsupportedLocale(let locale):
            "Apple SpeechTranscriber does not support locale \(locale)."
        case .assetUnsupported:
            "Apple SpeechTranscriber assets are unsupported for this configuration."
        case .assetNotInstalled(let status):
            "Apple SpeechTranscriber assets are not installed: \(status)."
        case .noCompatibleAudioFormat:
            "Apple SpeechTranscriber has no compatible audio format."
        case .streamAlreadyActive:
            "Apple SpeechTranscriber stream is already active."
        case .streamNotActive:
            "Apple SpeechTranscriber stream is not active."
        case .conversionFailed(let message):
            "Could not convert audio for Apple SpeechTranscriber: \(message)."
        }
    }
}

public actor AppleSpeechTranscriberBackend {
    public typealias EventHandler = @Sendable (AppleSpeechStreamEvent) -> Void
    public typealias DetectionHandler = @Sendable (Bool) -> Void

    private let requestedLocale: Locale
    private var resolvedLocale: Locale?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var detector: SpeechDetector?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Error>?
    private var detectorTask: Task<Void, Error>?
    private var analyzerFormat: AVAudioFormat?
    private var convertAnalyzerInput: ((AVAudioPCMBuffer) throws -> [AnalyzerInput])?
    private var flushAnalyzerInput: (() throws -> [AnalyzerInput])?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var converterOutputFormat: AVAudioFormat?
    private var finalResults: [FinalResult] = []
    private var latestPartial: PartialResult?

    public init(locale: Locale = Locale(identifier: "en_US")) {
        requestedLocale = locale
    }

    public func prepare() async throws {
        _ = try await locale()
        let module = makeTranscriber(locale: try await locale(), reportingOptions: [])
        try await ensureAssets(for: module)
    }

    public func transcribe(audioURL: URL) async throws -> String {
        let locale = try await locale()
        let module = makeTranscriber(locale: locale, reportingOptions: [])
        try await ensureAssets(for: module)
        let file = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(
            modules: [module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )

        async let transcript = collectTranscript(from: module)
        if let lastSampleTime = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await transcript
    }

    public func startStream(
        detectSpeech: Bool = false,
        onEvent: @escaping EventHandler,
        onDetection: DetectionHandler? = nil
    ) async throws {
        guard analyzer == nil else { throw AppleSpeechTranscriberError.streamAlreadyActive }

        let locale = try await locale()
        let module = makeTranscriber(
            locale: locale,
            reportingOptions: [.volatileResults, .fastResults]
        )
        let detector = detectSpeech ? SpeechDetector(
            detectionOptions: SpeechDetector.DetectionOptions(sensitivityLevel: .low),
            reportResults: true
        ) : nil
        let modules: [any SpeechModule] = if let detector {
            [detector, module]
        } else {
            [module]
        }
        try await ensureAssets(for: modules)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw AppleSpeechTranscriberError.noCompatibleAudioFormat
        }

        let analyzer = SpeechAnalyzer(
            modules: modules,
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        )
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        transcriber = module
        self.detector = detector
        inputContinuation = continuation
        analyzerFormat = format
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            let analyzerInputConverter = AnalyzerInputConverter(analyzerFormat: format)
            convertAnalyzerInput = { try analyzerInputConverter.convert($0, at: nil) }
            flushAnalyzerInput = { try analyzerInputConverter.flush() }
        }
        #endif
        converter = nil
        converterInputFormat = nil
        converterOutputFormat = nil
        finalResults = []
        latestPartial = nil

        resultTask = Task { [module] in
            for try await result in module.results {
                self.consume(result, onEvent: onEvent)
            }
        }

        if let detector {
            detectorTask = Task { [detector] in
                for try await result in detector.results {
                    DebugLog.write("speech detector result speech=\(result.speechDetected)")
                    onDetection?(result.speechDetected)
                }
            }
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            await cleanupAfterStream()
            throw error
        }
    }

    public func append(_ buffer: AVAudioPCMBuffer) async throws {
        guard let inputContinuation, let analyzerFormat else {
            throw AppleSpeechTranscriberError.streamNotActive
        }

        if let convertAnalyzerInput {
            for input in try convertAnalyzerInput(buffer) {
                inputContinuation.yield(input)
            }
            return
        }

        let converted = try convert(buffer, to: analyzerFormat)
        inputContinuation.yield(AnalyzerInput(buffer: converted))
    }

    public func finishStream() async throws -> String {
        guard let analyzer else { throw AppleSpeechTranscriberError.streamNotActive }

        do {
            if let flushAnalyzerInput {
                for input in try flushAnalyzerInput() {
                    inputContinuation?.yield(input)
                }
            }
            inputContinuation?.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await resultTask?.value
            try? await detectorTask?.value
            let text = currentTranscript(includePartial: false)
            await cleanupAfterStream()
            return text
        } catch {
            inputContinuation?.finish()
            await analyzer.cancelAndFinishNow()
            await cleanupAfterStream()
            throw error
        }
    }

    public func cancelStream() async {
        inputContinuation?.finish()
        await analyzer?.cancelAndFinishNow()
        resultTask?.cancel()
        detectorTask?.cancel()
        await cleanupAfterStream()
    }

    public static func isAvailable() -> Bool {
        SpeechTranscriber.isAvailable
    }

    private func locale() async throws -> Locale {
        if let resolvedLocale { return resolvedLocale }
        guard SpeechTranscriber.isAvailable else { throw AppleSpeechTranscriberError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw AppleSpeechTranscriberError.unsupportedLocale(requestedLocale.identifier)
        }
        resolvedLocale = locale
        return locale
    }

    private func collectTranscript(from module: SpeechTranscriber) async throws -> String {
        var finalParts: [String] = []
        var latestVolatile = ""
        for try await result in module.results {
            let text = normalized(result.text)
            guard !text.isEmpty else { continue }
            if result.isFinal {
                finalParts.append(text)
            } else {
                latestVolatile = text
            }
        }
        let final = normalized(finalParts.joined(separator: " "))
        return final.isEmpty ? latestVolatile : final
    }

    private func makeTranscriber(
        locale: Locale,
        reportingOptions: Set<SpeechTranscriber.ReportingOption>
    ) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: reportingOptions,
            attributeOptions: [.audioTimeRange]
        )
    }

    private func ensureAssets(for module: SpeechTranscriber) async throws {
        try await ensureAssets(for: [module])
    }

    private func ensureAssets(for modules: [any SpeechModule]) async throws {
        _ = try await AssetInventory.reserve(locale: try await locale())

        let status = await AssetInventory.status(forModules: modules)
        switch status {
        case .installed:
            return
        case .unsupported:
            throw AppleSpeechTranscriberError.assetUnsupported
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
            let updatedStatus = await AssetInventory.status(forModules: modules)
            guard updatedStatus == .installed else {
                throw AppleSpeechTranscriberError.assetNotInstalled(String(describing: updatedStatus))
            }
        @unknown default:
            throw AppleSpeechTranscriberError.assetNotInstalled(String(describing: status))
        }
    }

    private func consume(_ result: SpeechTranscriber.Result, onEvent: EventHandler) {
        let text = normalized(result.text)
        guard !text.isEmpty else { return }
        DebugLog.write("speech transcriber result final=\(result.isFinal) chars=\(text.count)")

        let start = result.range.start.seconds
        if result.isFinal {
            latestPartial = nil
            if let index = finalResults.firstIndex(where: { abs($0.start - start) < 0.001 }) {
                finalResults[index] = FinalResult(start: start, text: text)
            } else {
                finalResults.append(FinalResult(start: start, text: text))
                finalResults.sort { $0.start < $1.start }
            }
            onEvent(.final(currentTranscript(includePartial: false)))
        } else {
            latestPartial = PartialResult(start: start, text: text)
            onEvent(.partial(currentTranscript(includePartial: true)))
        }
    }

    private func currentTranscript(includePartial: Bool) -> String {
        var pieces = finalResults.map(\.text)
        if includePartial, let latestPartial {
            pieces.append(latestPartial.text)
        }
        return normalized(pieces.joined(separator: " "))
    }

    private func normalized(_ text: AttributedString) -> String {
        normalized(String(text.characters))
    }

    private func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = converter(for: buffer.format, outputFormat: outputFormat) else {
            throw AppleSpeechTranscriberError.conversionFailed("AVAudioConverter creation failed")
        }

        let sampleRateRatio = outputFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(max(1, ceil(Double(buffer.frameLength) * sampleRateRatio)))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            throw AppleSpeechTranscriberError.conversionFailed("output buffer creation failed")
        }

        var consumed = false
        var nsError: NSError?
        let status = converter.convert(to: outputBuffer, error: &nsError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        if status == .error {
            throw AppleSpeechTranscriberError.conversionFailed(nsError?.localizedDescription ?? "unknown converter error")
        }
        return outputBuffer
    }

    private func converter(for inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) -> AVAudioConverter? {
        if let converter,
           converterInputFormat == inputFormat,
           converterOutputFormat == outputFormat {
            return converter
        }

        converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        converter?.primeMethod = .none
        converterInputFormat = inputFormat
        converterOutputFormat = outputFormat
        return converter
    }

    private func cleanupAfterStream() async {
        analyzer = nil
        transcriber = nil
        detector = nil
        inputContinuation = nil
        resultTask = nil
        detectorTask = nil
        analyzerFormat = nil
        convertAnalyzerInput = nil
        flushAnalyzerInput = nil
        converter = nil
        converterInputFormat = nil
        converterOutputFormat = nil
    }
}

private struct FinalResult: Sendable {
    let start: Double
    let text: String
}

private struct PartialResult: Sendable {
    let start: Double
    let text: String
}
