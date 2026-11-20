@preconcurrency import CoreML
import FluidAudio
import Foundation

public actor FluidSpeechProBackend {
    private static let revision = "3b9d38a93d606f84011e5a0a669b7ea146375a22"
    private static let modelURL = URL(string: "https://huggingface.co/FluidVoice-Labs/fluid-speech-pro-coreml/resolve/\(revision)/")!
    private static let vocabularyPath = "parakeet_v3_vocab.json"

    static let assets: [(path: String, bytes: Int64)] = [
        ("Decoder.mlmodelc/analytics/coremldata.bin", 243),
        ("Decoder.mlmodelc/coremldata.bin", 491),
        ("Decoder.mlmodelc/metadata.json", 3_311),
        ("Decoder.mlmodelc/model.mil", 11_823),
        ("Decoder.mlmodelc/weights/weight.bin", 23_604_992),
        ("Encoder.mlmodelc/analytics/coremldata.bin", 243),
        ("Encoder.mlmodelc/coremldata.bin", 427),
        ("Encoder.mlmodelc/metadata.json", 2_758),
        ("Encoder.mlmodelc/model.mil", 621_903),
        ("Encoder.mlmodelc/weights/weight.bin", 613_088_448),
        ("JointDecision.mlmodelc/analytics/coremldata.bin", 243),
        ("JointDecision.mlmodelc/coremldata.bin", 462),
        ("JointDecision.mlmodelc/metadata.json", 2_728),
        ("JointDecision.mlmodelc/model.mil", 7_178),
        ("JointDecision.mlmodelc/weights/weight.bin", 12_642_764),
        ("Preprocessor.mlmodelc/analytics/coremldata.bin", 243),
        ("Preprocessor.mlmodelc/coremldata.bin", 429),
        ("Preprocessor.mlmodelc/metadata.json", 2_606),
        ("Preprocessor.mlmodelc/model.mil", 11_891),
        ("Preprocessor.mlmodelc/weights/weight.bin", 2_150_580),
        (vocabularyPath, 151_122),
    ]

    private enum LoadState {
        case unloaded
        case loading(Task<AsrManager, Error>)
        case ready(AsrManager)
    }

    private let cacheDirectory: URL
    private let onDownloadProgress: @MainActor @Sendable (Progress?) -> Void
    private var loadState = LoadState.unloaded
    private var transcribing = false
    private var transcriptionWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        cacheDirectory: URL? = nil,
        onDownloadProgress: @escaping @MainActor @Sendable (Progress?) -> Void = { _ in }
    ) {
        self.cacheDirectory = cacheDirectory ?? URL.cachesDirectory
            .appending(path: "Mimi/FluidSpeechPro/\(Self.revision)", directoryHint: .isDirectory)
        self.onDownloadProgress = onDownloadProgress
    }

    public func prepare() async throws {
        _ = try await manager()
    }

    public func transcribe(audioURL: URL) async throws -> String {
        guard audioURL.isFileURL else { throw URLError(.unsupportedURL) }
        let manager = try await manager()
        // FluidAudio uses one progress session per manager, even for overlapping batch calls.
        if transcribing {
            await withCheckedContinuation { transcriptionWaiters.append($0) }
        } else {
            transcribing = true
        }
        defer {
            if transcriptionWaiters.isEmpty {
                transcribing = false
            } else {
                transcriptionWaiters.removeFirst().resume()
            }
        }
        try Task.checkCancellation()
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(audioURL, decoderState: &decoderState).text
    }

    private func manager() async throws -> AsrManager {
        switch loadState {
        case .ready(let manager): return manager
        case .loading(let task): return try await task.value
        case .unloaded:
            let task = Task {
                do {
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.urlCache = nil
                    let session = URLSession(configuration: configuration)
                    defer { session.finishTasksAndInvalidate() }
                    try await Self.installMissingAssets(in: cacheDirectory, onDownloadProgress: onDownloadProgress) { url, progress, bytes, install in
                        try await withCheckedThrowingContinuation { continuation in
                            let task = session.downloadTask(with: url) { file, response, error in
                                if let error {
                                    continuation.resume(throwing: error)
                                } else if let file, let response {
                                    // URLSession removes the temporary file when this callback returns.
                                    continuation.resume(with: Result { try install(file, response) })
                                } else {
                                    continuation.resume(throwing: URLError(.badServerResponse))
                                }
                            }
                            progress.addChild(task.progress, withPendingUnitCount: bytes)
                            task.resume()
                        }
                    }
                    let manager = try await Self.loadManager(from: cacheDirectory)
                    loadState = .ready(manager)
                    return manager
                } catch {
                    loadState = .unloaded
                    throw error
                }
            }
            loadState = .loading(task)
            return try await task.value
        }
    }

    static func hasExpectedSize(_ bytes: Int64, at url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return values?.isRegularFile == true && values?.fileSize.map(Int64.init) == bytes
    }

    static func installMissingAssets(
        in directory: URL,
        onDownloadProgress: @MainActor @Sendable (Progress?) -> Void,
        download: (URL, Progress, Int64, @escaping @Sendable (URL, URLResponse) throws -> Void) async throws -> Void
    ) async throws {
        let totalBytes = assets.reduce(0) { $0 + $1.bytes }
        let missing = assets.filter { !hasExpectedSize($0.bytes, at: directory.appending(path: $0.path)) }
        guard !missing.isEmpty else { return }

        let progress = Progress.discreteProgress(totalUnitCount: totalBytes)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.completedUnitCount = totalBytes - missing.reduce(0) { $0 + $1.bytes }
        await onDownloadProgress(progress)
        do {
            for asset in missing {
                let destination = directory.appending(path: asset.path)
                try await download(modelURL.appending(path: asset.path), progress, asset.bytes) { temporaryFile, response in
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          hasExpectedSize(asset.bytes, at: temporaryFile) else {
                        throw ModelError.invalidDownload(asset.path)
                    }
                    let files = FileManager.default
                    try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if files.fileExists(atPath: destination.path) {
                        _ = try files.replaceItemAt(destination, withItemAt: temporaryFile)
                    } else {
                        try files.moveItem(at: temporaryFile, to: destination)
                    }
                }
            }
        } catch {
            await onDownloadProgress(nil)
            throw error
        }
        await onDownloadProgress(nil)
    }

    private static func loadManager(from directory: URL) async throws -> AsrManager {
        let vocabData = try Data(contentsOf: directory.appending(path: vocabularyPath))
        let tokens = try JSONDecoder().decode([String: String].self, from: vocabData)
        let vocabulary = tokens.reduce(into: [Int: String]()) { vocabulary, entry in
            if let id = Int(entry.key) { vocabulary[id] = entry.value }
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let preprocessorConfiguration = MLModelConfiguration()
        preprocessorConfiguration.computeUnits = .cpuOnly

        let models = try await AsrModels(
            encoder: MLModel.load(contentsOf: directory.appending(path: "Encoder.mlmodelc"), configuration: configuration),
            preprocessor: MLModel.load(contentsOf: directory.appending(path: "Preprocessor.mlmodelc"), configuration: preprocessorConfiguration),
            decoder: MLModel.load(contentsOf: directory.appending(path: "Decoder.mlmodelc"), configuration: configuration),
            joint: MLModel.load(contentsOf: directory.appending(path: "JointDecision.mlmodelc"), configuration: configuration),
            configuration: configuration,
            vocabulary: vocabulary,
            version: .v3
        )
        return AsrManager(models: models)
    }

    private enum ModelError: LocalizedError {
        case invalidDownload(String)

        var errorDescription: String? {
            switch self {
            case .invalidDownload(let path): "Could not download a complete Fluid Speech Pro model file (\(path))."
            }
        }
    }
}
