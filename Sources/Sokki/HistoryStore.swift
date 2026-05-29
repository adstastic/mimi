import Combine
import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [TranscriptEntry] = []

    private let limit: Int

    init(limit: Int = 20) {
        self.limit = limit
    }

    var lastTranscript: String? {
        entries.first?.text
    }

    func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        entries.insert(TranscriptEntry(text: trimmed, createdAt: Date()), at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
    }
}

struct TranscriptEntry: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let createdAt: Date
}
