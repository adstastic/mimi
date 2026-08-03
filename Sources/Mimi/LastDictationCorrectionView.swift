import SwiftUI

struct LastDictationCorrectionView: View {
    let entry: TranscriptEntry
    @Binding private var vocabularyEntries: [VocabularyEntry]
    let save: (UUID, String) -> Bool

    @State private var correctedText: String
    @State private var heard = ""
    @State private var written = ""
    @State private var validationMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(
        entry: TranscriptEntry,
        vocabularyEntries: Binding<[VocabularyEntry]>,
        save: @escaping (UUID, String) -> Bool
    ) {
        self.entry = entry
        _vocabularyEntries = vocabularyEntries
        self.save = save
        _correctedText = State(initialValue: entry.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CorrectionHeader(entry: entry)
            OriginalTranscript(text: entry.text)
            CorrectedTranscriptEditor(text: $correctedText)
            VocabularyRuleEditor(heard: $heard, written: $written)
            CorrectionFooter(
                message: validationMessage,
                canSave: !correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                canLearn: canLearn,
                cancel: { dismiss() },
                save: saveCorrection,
                saveAndLearn: saveCorrectionAndLearn
            )
        }
        .padding(16)
        .frame(width: 560, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: correctedText, updateSuggestion)
    }

    private var canLearn: Bool {
        !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateSuggestion(oldValue: String, newValue: String) {
        guard let suggestion = VocabularyCorrectionSuggestion.infer(
            source: entry.text,
            corrected: newValue
        ) else {
            heard = ""
            written = ""
            return
        }
        heard = suggestion.heard
        written = suggestion.written
        validationMessage = nil
    }

    private func saveCorrection() {
        guard save(entry.id, correctedText) else {
            validationMessage = "A newer dictation replaced this one. Open Correct again."
            return
        }
        dismiss()
    }

    private func saveCorrectionAndLearn() {
        do {
            let updatedEntries = try VocabularyEntryUpdater.addingCorrection(
                heard: heard,
                written: written,
                to: vocabularyEntries
            )
            guard save(entry.id, correctedText) else {
                validationMessage = "A newer dictation replaced this one. Open Correct again."
                return
            }
            vocabularyEntries = updatedEntries
            dismiss()
        } catch let error as VocabularyValidationError {
            validationMessage = error.message
        } catch {
            validationMessage = error.localizedDescription
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
                .lineLimit(2)
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
                .frame(height: 90)
                .accessibilityLabel("Corrected transcript")
        }
    }
}

private struct VocabularyRuleEditor: View {
    @Binding var heard: String
    @Binding var written: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Vocabulary rule")
                .font(.headline)
            HStack(spacing: 8) {
                LabeledContent("Mimi heard") {
                    TextField("pie torch", text: $heard)
                        .accessibilityLabel("Mimi heard")
                }
                LabeledContent("Write") {
                    TextField("PyTorch", text: $written)
                        .accessibilityLabel("Write instead")
                }
            }
            Text("Review this suggestion before adding it. Mimi never learns corrections automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CorrectionFooter: View {
    let message: String?
    let canSave: Bool
    let canLearn: Bool
    let cancel: () -> Void
    let save: () -> Void
    let saveAndLearn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message ?? " ")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .disabled(!canSave)
                Button("Save + Add Vocabulary", action: saveAndLearn)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave || !canLearn)
            }
        }
    }
}

private extension VocabularyValidationError {
    var message: String {
        switch self {
        case .emptyWrittenForm:
            "Both vocabulary fields are required."
        case .conflictingPhrase(let phrase, let first, let second):
            "“\(phrase)” is already used by “\(first)” and “\(second)”."
        }
    }
}
