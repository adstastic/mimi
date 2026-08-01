import SwiftUI

struct VocabularySettingsView: View {
    @Binding private var entries: [VocabularyEntry]
    @State private var drafts: [VocabularyDraft]
    @Environment(\.dismiss) private var dismiss

    init(entries: Binding<[VocabularyEntry]>) {
        _entries = entries
        _drafts = State(initialValue: entries.wrappedValue.map(VocabularyDraft.init))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VocabularyEditorHeader(add: addEntry)
            VocabularyEntryList(drafts: $drafts)
            VocabularyEditorFooter(
                error: validationError,
                cancel: { dismiss() },
                save: save
            )
        }
        .padding(16)
        .frame(width: 540, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var validationError: VocabularyValidationError? {
        VocabularyValidator.validate(drafts.map(\.entry))
    }

    private func addEntry() {
        drafts.append(VocabularyDraft())
    }

    private func save() {
        guard validationError == nil else { return }
        entries = drafts.map(\.entry)
        dismiss()
    }
}

private struct VocabularyDraft: Identifiable {
    let id: UUID
    var writtenForm: String
    var aliases: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        writtenForm: String = "",
        aliases: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.writtenForm = writtenForm
        self.aliases = aliases
        self.isEnabled = isEnabled
    }

    init(_ entry: VocabularyEntry) {
        self.init(
            id: entry.id,
            writtenForm: entry.writtenForm,
            aliases: entry.spokenAliases.joined(separator: ", "),
            isEnabled: entry.isEnabled
        )
    }

    var entry: VocabularyEntry {
        VocabularyEntry(
            id: id,
            writtenForm: writtenForm.trimmingCharacters(in: .whitespacesAndNewlines),
            spokenAliases: normalizedAliases,
            isEnabled: isEnabled
        )
    }

    private var normalizedAliases: [String] {
        var seen: Set<String> = []
        return aliases
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(VocabularyComparison.key($0)).inserted }
    }
}

private struct VocabularyEditorHeader: View {
    let add: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Custom Vocabulary")
                    .font(.title2.bold())
                Text("Set exact spelling and casing, then add only aliases Mimi actually hears.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: add) {
                Label("Add", systemImage: "plus")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct VocabularyEntryList: View {
    @Binding var drafts: [VocabularyDraft]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))

            if drafts.isEmpty {
                VocabularyEmptyState()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($drafts) { $draft in
                            VStack(spacing: 0) {
                                VocabularyDraftRow(draft: $draft) {
                                    drafts.removeAll { $0.id == draft.id }
                                }
                                .padding(8)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .frame(height: 220)
        .clipped()
    }
}

private struct VocabularyEmptyState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.book.closed")
                .font(.largeTitle)
            Text("No Vocabulary Yet")
                .font(.headline)
            Text("Add exact written forms and optional spoken aliases.")
                .font(.callout)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding()
    }
}

private struct VocabularyDraftRow: View {
    @Binding var draft: VocabularyDraft
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle("Enabled", isOn: $draft.isEnabled)
                .labelsHidden()
                .help("Enable this vocabulary entry")

            VStack(spacing: 6) {
                VocabularyTextField(label: "Write", prompt: "PyTorch", text: $draft.writtenForm)
                VocabularyTextField(label: "Say", prompt: "pie torch, pie talk", text: $draft.aliases)
            }

            Button(role: .destructive, action: delete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete vocabulary entry")
        }
        .padding(.vertical, 4)
    }
}

private struct VocabularyTextField: View {
    let label: LocalizedStringKey
    let prompt: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            TextField(prompt, text: $text)
                .accessibilityLabel(label)
        }
    }
}

private struct VocabularyEditorFooter: View {
    let error: VocabularyValidationError?
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VocabularyValidationMessage(error: error)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(error != nil)
            }
        }
    }
}

private struct VocabularyValidationMessage: View {
    let error: VocabularyValidationError?

    var body: some View {
        HStack {
            if let error {
                switch error {
                case .emptyWrittenForm:
                    Label("Each entry needs a written form.", systemImage: "exclamationmark.triangle.fill")
                case .conflictingPhrase(let phrase, let first, let second):
                    Label(
                        "“\(phrase)” is already used by “\(first)” and “\(second)”.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.red)
        .lineLimit(1)
        .frame(height: 16, alignment: .leading)
    }
}
