import Combine
import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    static let productionAudioStorageURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mimi", isDirectory: true)
        .appendingPathComponent("latest-dictation.wav")

    @Published private(set) var latest: TranscriptEntry?

    private let audioStorageURL: URL?

    init(audioStorageURL: URL? = nil) {
        self.audioStorageURL = audioStorageURL
        if let audioStorageURL {
            try? FileManager.default.removeItem(at: audioStorageURL)
        }
    }

    var lastTranscript: String? {
        latest?.text
    }

    func record(
        sourceText: String,
        text: String,
        backend: ASRBackend,
        audioURL: URL?
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        removeRetainedAudio()
        let retainedAudioURL = audioURL.flatMap(retainAudio)
        latest = TranscriptEntry(
            sourceText: sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
            text: trimmedText,
            backend: backend,
            audioURL: retainedAudioURL,
            createdAt: Date()
        )
    }

    @discardableResult
    func updateLastTranscript(id: UUID, text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var latest, latest.id == id else { return nil }
        latest.text = trimmed
        self.latest = latest
        return trimmed
    }

    func clear() {
        latest = nil
        removeRetainedAudio()
    }

    private func retainAudio(from sourceURL: URL) -> URL? {
        guard let audioStorageURL,
              FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: audioStorageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceURL, to: audioStorageURL)
            return audioStorageURL
        } catch {
            try? FileManager.default.removeItem(at: audioStorageURL)
            return nil
        }
    }

    private func removeRetainedAudio() {
        guard let audioStorageURL else { return }
        try? FileManager.default.removeItem(at: audioStorageURL)
    }
}

struct TranscriptEntry: Identifiable, Equatable {
    let id: UUID
    let sourceText: String
    var text: String
    let backend: ASRBackend
    let audioURL: URL?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        sourceText: String,
        text: String,
        backend: ASRBackend,
        audioURL: URL?,
        createdAt: Date
    ) {
        self.id = id
        self.sourceText = sourceText
        self.text = text
        self.backend = backend
        self.audioURL = audioURL
        self.createdAt = createdAt
    }
}
