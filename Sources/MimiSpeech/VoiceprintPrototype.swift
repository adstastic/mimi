@preconcurrency import AVFoundation
@preconcurrency import FluidAudio
import Foundation

public struct VoiceprintProfile: Codable, Equatable, Sendable {
    public let version: Int
    public let sampleCount: Int
    public let embedding: [Float]
    public let threshold: Float

    public init(version: Int = 2, sampleCount: Int, embedding: [Float], threshold: Float) {
        self.version = version
        self.sampleCount = sampleCount
        self.embedding = embedding
        self.threshold = threshold
    }
}

public struct VoiceprintVerification: Equatable, Sendable {
    public let accepted: Bool
    public let distance: Float
    public let threshold: Float
    public let embeddingDimensions: Int

    public init(accepted: Bool, distance: Float, threshold: Float, embeddingDimensions: Int) {
        self.accepted = accepted
        self.distance = distance
        self.threshold = threshold
        self.embeddingDimensions = embeddingDimensions
    }
}

public struct VoiceprintExtraction: Equatable, Sendable {
    public let audioURL: URL?
    public let totalSegmentCount: Int
    public let keptSegmentCount: Int
    public let keptDurationSeconds: Float
    public let bestDistance: Float?
    public let threshold: Float

    public init(
        audioURL: URL?,
        totalSegmentCount: Int,
        keptSegmentCount: Int,
        keptDurationSeconds: Float,
        bestDistance: Float?,
        threshold: Float
    ) {
        self.audioURL = audioURL
        self.totalSegmentCount = totalSegmentCount
        self.keptSegmentCount = keptSegmentCount
        self.keptDurationSeconds = keptDurationSeconds
        self.bestDistance = bestDistance
        self.threshold = threshold
    }
}

public enum VoiceprintPrototype {
    public enum VoiceprintError: LocalizedError {
        case noAudio
        case profileMissing(URL)
        case incompatibleProfile
        case outputFailed

        public var errorDescription: String? {
            switch self {
            case .noAudio:
                "No audio samples were available for speaker embedding."
            case .profileMissing(let url):
                "Voiceprint profile does not exist: \(url.path)"
            case .incompatibleProfile:
                "Voiceprint profile is incompatible with this speaker-embedding prototype."
            case .outputFailed:
                "Could not write extracted speaker audio."
            }
        }
    }

    public static let defaultProfileURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/mimi/voiceprint-prototype.json")
    public static let enrollmentPrompt = "The birch canoe slid on the smooth planks. Glue the sheet to the dark blue background."

    static let sampleRate = 16_000
    static let defaultThreshold: Float = 0.78
    private static let minimumThreshold: Float = 0.45
    private static let maximumThreshold: Float = 0.85

    public static func loadProfile(from url: URL = defaultProfileURL) throws -> VoiceprintProfile {
        guard FileManager.default.fileExists(atPath: url.path) else { throw VoiceprintError.profileMissing(url) }
        let data = try Data(contentsOf: url)
        let profile = try JSONDecoder().decode(VoiceprintProfile.self, from: data)
        guard profile.version == 2, !profile.embedding.isEmpty else { throw VoiceprintError.incompatibleProfile }
        return profile
    }

    public static func save(_ profile: VoiceprintProfile, to url: URL = defaultProfileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profile)
        try data.write(to: url, options: .atomic)
    }

    public static func makeProfile(audioURLs: [URL]) async throws -> VoiceprintProfile {
        try await VoiceprintEmbeddingService().makeProfile(audioURLs: audioURLs)
    }

    public static func verify(audioURL: URL, against profile: VoiceprintProfile) async throws -> VoiceprintVerification {
        try await VoiceprintEmbeddingService().verify(audioURL: audioURL, against: profile)
    }

    static func makeProfile(from embeddings: [[Float]], thresholdOverride: Float? = nil) throws -> VoiceprintProfile {
        guard !embeddings.isEmpty else { throw VoiceprintError.noAudio }
        let centroid = normalize(average(embeddings))
        let distances = embeddings.map { cosineDistance($0, centroid) }
        let meanDistance = distances.reduce(0, +) / Float(max(distances.count, 1))
        let variance = distances.reduce(Float(0)) { $0 + pow($1 - meanDistance, 2) } / Float(max(distances.count, 1))
        let learnedThreshold = clamp(meanDistance + 0.10 + 3 * sqrt(variance), minimumThreshold, maximumThreshold)
        return VoiceprintProfile(
            sampleCount: embeddings.count,
            embedding: centroid,
            threshold: thresholdOverride ?? max(defaultThreshold, learnedThreshold)
        )
    }

    static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return .infinity }
        let left = normalize(Array(lhs.prefix(count)))
        let right = normalize(Array(rhs.prefix(count)))
        let dot = zip(left, right).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        return 1 - dot
    }

    private static func average(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var result = [Float](repeating: 0, count: first.count)
        var count: Float = 0
        for vector in vectors where vector.count == first.count {
            for index in result.indices {
                result[index] += vector[index]
            }
            count += 1
        }
        guard count > 0 else { return result }
        return result.map { $0 / count }
    }

    private static func normalize(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private static func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
        min(upper, max(lower, value))
    }
}

public actor VoiceprintEmbeddingService {
    private var diarizer: DiarizerManager?

    public init() {}

    public func makeProfile(audioURLs: [URL], thresholdOverride: Float? = nil) async throws -> VoiceprintProfile {
        guard !audioURLs.isEmpty else { throw VoiceprintPrototype.VoiceprintError.noAudio }
        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(audioURLs.count)
        for audioURL in audioURLs {
            embeddings.append(try await embedding(audioURL: audioURL))
        }
        return try VoiceprintPrototype.makeProfile(from: embeddings, thresholdOverride: thresholdOverride)
    }

    public func verify(audioURL: URL, against profile: VoiceprintProfile) async throws -> VoiceprintVerification {
        guard profile.version == 2, !profile.embedding.isEmpty else {
            throw VoiceprintPrototype.VoiceprintError.incompatibleProfile
        }
        let candidate = try await embedding(audioURL: audioURL)
        let distance = VoiceprintPrototype.cosineDistance(candidate, profile.embedding)
        return VoiceprintVerification(
            accepted: distance <= profile.threshold,
            distance: distance,
            threshold: profile.threshold,
            embeddingDimensions: candidate.count
        )
    }

    public func extractOwnerSpeech(audioURL: URL, profile: VoiceprintProfile) async throws -> VoiceprintExtraction {
        guard profile.version == 2, !profile.embedding.isEmpty else {
            throw VoiceprintPrototype.VoiceprintError.incompatibleProfile
        }
        let samples = try AudioConverter().resampleAudioFile(audioURL)
        guard !samples.isEmpty else { throw VoiceprintPrototype.VoiceprintError.noAudio }

        let diarization = try await manager().performCompleteDiarization(
            samples,
            sampleRate: VoiceprintPrototype.sampleRate
        )
        let scored = diarization.segments.map { segment in
            (segment: segment, distance: VoiceprintPrototype.cosineDistance(segment.embedding, profile.embedding))
        }
        let kept = scored
            .filter { $0.distance <= profile.threshold }
            .sorted { $0.segment.startTimeSeconds < $1.segment.startTimeSeconds }
        let bestDistance = scored.map(\.distance).min()

        guard !kept.isEmpty else {
            return VoiceprintExtraction(
                audioURL: nil,
                totalSegmentCount: scored.count,
                keptSegmentCount: 0,
                keptDurationSeconds: 0,
                bestDistance: bestDistance,
                threshold: profile.threshold
            )
        }

        var ownerSamples: [Float] = []
        let silence = [Float](repeating: 0, count: Int(0.15 * Float(VoiceprintPrototype.sampleRate)))
        var keptDuration: Float = 0
        for item in kept {
            let start = max(0, Int(item.segment.startTimeSeconds * Float(VoiceprintPrototype.sampleRate)))
            let end = min(samples.count, Int(item.segment.endTimeSeconds * Float(VoiceprintPrototype.sampleRate)))
            guard end > start else { continue }
            if !ownerSamples.isEmpty { ownerSamples.append(contentsOf: silence) }
            ownerSamples.append(contentsOf: samples[start..<end])
            keptDuration += Float(end - start) / Float(VoiceprintPrototype.sampleRate)
        }
        guard !ownerSamples.isEmpty else { throw VoiceprintPrototype.VoiceprintError.noAudio }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-owner-")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try writeWAV(samples: ownerSamples, to: outputURL)
        return VoiceprintExtraction(
            audioURL: outputURL,
            totalSegmentCount: scored.count,
            keptSegmentCount: kept.count,
            keptDurationSeconds: keptDuration,
            bestDistance: bestDistance,
            threshold: profile.threshold
        )
    }

    private func embedding(audioURL: URL) async throws -> [Float] {
        let samples = try AudioConverter().resampleAudioFile(audioURL)
        guard !samples.isEmpty else { throw VoiceprintPrototype.VoiceprintError.noAudio }
        return try await manager().extractSpeakerEmbedding(from: samples)
    }

    private func manager() async throws -> DiarizerManager {
        if let diarizer { return diarizer }
        let models = try await DiarizerModels.downloadIfNeeded()
        let diarizer = DiarizerManager()
        diarizer.initialize(models: models)
        self.diarizer = diarizer
        return diarizer
    }

    private func writeWAV(samples: [Float], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(VoiceprintPrototype.sampleRate),
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw VoiceprintPrototype.VoiceprintError.outputFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            buffer.floatChannelData?[0].update(from: pointer.baseAddress!, count: samples.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
