import SwiftUI

struct LastDictationCorrectionView: View {
    let entry: TranscriptEntry
    let save: (UUID, String, [VocabularyCorrectionSuggestion]) -> Result<Void, Error>

    @State private var correctedText: String
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(
        entry: TranscriptEntry,
        save: @escaping (UUID, String, [VocabularyCorrectionSuggestion]) -> Result<Void, Error>
    ) {
        self.entry = entry
        self.save = save
        _correctedText = State(initialValue: entry.text)
    }

    private var corrections: [VocabularyCorrectionSuggestion] {
        VocabularyCorrectionSuggestion.inferAll(
            source: entry.text,
            corrected: correctedText
        ).filter {
            VocabularyCorrector.contains(phrase: $0.heard, in: entry.sourceText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CorrectionHeader(entry: entry)
            OriginalTranscript(text: entry.text)
            CorrectedTranscriptEditor(text: $correctedText)
            CorrectionLearningSummary(count: corrections.count)
            Spacer()
            CorrectionFooter(
                errorMessage: errorMessage,
                canSave: !correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                cancel: { dismiss() },
                save: saveCorrection
            )
        }
        .padding(16)
        .frame(width: 560, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: correctedText) { _, _ in errorMessage = nil }
    }

    private func saveCorrection() {
        switch save(entry.id, correctedText, corrections) {
        case .success:
            dismiss()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

private struct CorrectionHeader: View {
    let entry: TranscriptEntry

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Correct Last Dictation")
                    .font(.title2.bold())
                Text("\(entry.backend.displayName) · Saving copies corrected text to clipboard.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.audioURL != nil {
                Label("Audio kept", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OriginalTranscript: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mimi wrote")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CorrectedTranscriptEditor: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Correct it")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .frame(height: 140)
                .accessibilityLabel("Corrected transcript")
        }
    }
}

private struct CorrectionLearningSummary: View {
    let count: Int

    var body: some View {
        Label(message, systemImage: "arrow.triangle.branch")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var message: String {
        if count == 0 {
            "No word replacements detected; only corrected text will be saved."
        } else if count == 1 {
            "1 word-level replacement will be written to config.json."
        } else {
            "\(count) word-level replacements will be written to config.json."
        }
    }
}

private struct CorrectionFooter: View {
    let errorMessage: String?
    let canSave: Bool
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(errorMessage ?? " ")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save Correction", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
    }
}
