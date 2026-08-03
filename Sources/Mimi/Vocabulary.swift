import Foundation

public struct VocabularyEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var writtenForm: String
    public var spokenAliases: [String]
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        writtenForm: String,
        spokenAliases: [String] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.writtenForm = writtenForm
        self.spokenAliases = spokenAliases
        self.isEnabled = isEnabled
    }
}

enum VocabularyValidationError: Error, Equatable {
    case emptyWrittenForm
    case conflictingPhrase(String, firstWrittenForm: String, secondWrittenForm: String)
}

enum VocabularyValidator {
    static func validate(_ entries: [VocabularyEntry]) -> VocabularyValidationError? {
        var owners: [String: (entryIndex: Int, writtenForm: String)] = [:]

        for (entryIndex, entry) in entries.enumerated() {
            let writtenForm = entry.writtenForm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !writtenForm.isEmpty else { return .emptyWrittenForm }
            var ownKeys: Set<String> = []

            for source in [writtenForm] + entry.spokenAliases {
                let phrase = source.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !phrase.isEmpty else { continue }
                let key = VocabularyComparison.key(phrase)
                guard !key.isEmpty, ownKeys.insert(key).inserted else { continue }

                if let owner = owners[key], owner.entryIndex != entryIndex {
                    return .conflictingPhrase(
                        phrase,
                        firstWrittenForm: owner.writtenForm,
                        secondWrittenForm: writtenForm
                    )
                }
                owners[key] = (entryIndex, writtenForm)
            }
        }
        return nil
    }
}

struct VocabularyCorrectionSuggestion: Equatable {
    let heard: String
    let written: String

    static func infer(source: String, corrected: String) -> VocabularyCorrectionSuggestion? {
        guard source != corrected else { return nil }
        let sourceCharacters = Array(source)
        let correctedCharacters = Array(corrected)
        let sharedCount = min(sourceCharacters.count, correctedCharacters.count)

        var prefixCount = 0
        while prefixCount < sharedCount,
              sourceCharacters[prefixCount] == correctedCharacters[prefixCount] {
            prefixCount += 1
        }

        while prefixCount > 0,
              VocabularyComparison.isWordCharacter(sourceCharacters[prefixCount - 1]),
              VocabularyComparison.isWordCharacter(correctedCharacters[prefixCount - 1]) {
            prefixCount -= 1
        }

        var suffixCount = 0
        while suffixCount < sourceCharacters.count - prefixCount,
              suffixCount < correctedCharacters.count - prefixCount,
              sourceCharacters[sourceCharacters.count - suffixCount - 1]
                == correctedCharacters[correctedCharacters.count - suffixCount - 1] {
            suffixCount += 1
        }
        while suffixCount > 0 {
            let sourceStart = sourceCharacters.count - suffixCount
            let correctedStart = correctedCharacters.count - suffixCount
            let startsInsideWord = VocabularyComparison.isWordCharacter(sourceCharacters[sourceStart])
                || VocabularyComparison.isWordCharacter(correctedCharacters[correctedStart])
            if !startsInsideWord { break }
            suffixCount -= 1
        }

        let heard = String(sourceCharacters[prefixCount ..< sourceCharacters.count - suffixCount])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let written = String(correctedCharacters[prefixCount ..< correctedCharacters.count - suffixCount])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !written.isEmpty else { return nil }
        return VocabularyCorrectionSuggestion(heard: heard, written: written)
    }
}

enum VocabularyEntryUpdater {
    static func addingCorrection(
        heard: String,
        written: String,
        to entries: [VocabularyEntry]
    ) throws -> [VocabularyEntry] {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !written.isEmpty else {
            throw VocabularyValidationError.emptyWrittenForm
        }

        var updated = entries
        let writtenKey = VocabularyComparison.key(written)
        if let index = updated.firstIndex(where: {
            VocabularyComparison.key($0.writtenForm.trimmingCharacters(in: .whitespacesAndNewlines)) == writtenKey
        }) {
            updated[index].isEnabled = true
            let existingKeys = Set(
                ([updated[index].writtenForm] + updated[index].spokenAliases).map(VocabularyComparison.key)
            )
            if !existingKeys.contains(VocabularyComparison.key(heard)) {
                updated[index].spokenAliases.append(heard)
            }
        } else {
            updated.append(VocabularyEntry(writtenForm: written, spokenAliases: [heard]))
        }

        if let error = VocabularyValidator.validate(updated) {
            throw error
        }
        return updated
    }
}

enum VocabularyCorrector {
    private struct Phrase {
        let key: String
        let replacement: String
    }

    private struct Match {
        let range: Range<String.Index>
        let replacement: String
        let length: Int
    }

    static func correct(_ text: String, entries: [VocabularyEntry]) -> String {
        guard !text.isEmpty else { return text }
        let phrases = unambiguousPhrases(from: entries)
        guard !phrases.isEmpty else { return text }

        var candidates: [Match] = []
        for phrase in phrases {
            candidates.append(contentsOf: matches(for: phrase, in: text))
        }
        guard !candidates.isEmpty else { return text }

        candidates.sort {
            if $0.range.lowerBound != $1.range.lowerBound {
                return $0.range.lowerBound < $1.range.lowerBound
            }
            return $0.length > $1.length
        }

        var selected: [Match] = []
        var cursor = text.startIndex
        for match in candidates where match.range.lowerBound >= cursor {
            selected.append(match)
            cursor = match.range.upperBound
        }

        var corrected = ""
        corrected.reserveCapacity(text.count)
        cursor = text.startIndex
        for match in selected {
            corrected.append(contentsOf: text[cursor ..< match.range.lowerBound])
            corrected.append(match.replacement)
            cursor = match.range.upperBound
        }
        corrected.append(contentsOf: text[cursor...])
        return corrected
    }

    private static func unambiguousPhrases(from entries: [VocabularyEntry]) -> [Phrase] {
        var owners: [String: (entryIndex: Int, replacement: String)] = [:]
        var conflicts: Set<String> = []

        for (entryIndex, entry) in entries.enumerated() where entry.isEnabled {
            let replacement = entry.writtenForm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !replacement.isEmpty else { continue }

            for source in [replacement] + entry.spokenAliases {
                let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let key = VocabularyComparison.key(trimmed)
                guard !key.isEmpty, !conflicts.contains(key) else { continue }

                if let owner = owners[key] {
                    if owner.entryIndex != entryIndex {
                        owners.removeValue(forKey: key)
                        conflicts.insert(key)
                    }
                } else {
                    owners[key] = (entryIndex, replacement)
                }
            }
        }

        return owners.map { Phrase(key: $0.key, replacement: $0.value.replacement) }
    }

    private static func matches(for phrase: Phrase, in text: String) -> [Match] {
        var result: [Match] = []
        var lowerBound = text.startIndex

        while lowerBound < text.endIndex {
            var upperBound = lowerBound
            while upperBound < text.endIndex {
                upperBound = text.index(after: upperBound)
                let range = lowerBound ..< upperBound
                let candidateKey = VocabularyComparison.key(String(text[range]))
                guard phrase.key.hasPrefix(candidateKey) else { break }

                if candidateKey == phrase.key, hasWholeBoundaries(range, in: text) {
                    result.append(Match(
                        range: range,
                        replacement: phrase.replacement,
                        length: text.distance(from: lowerBound, to: upperBound)
                    ))
                }
            }
            lowerBound = text.index(after: lowerBound)
        }
        return result
    }

    private static func hasWholeBoundaries(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let previous = text[text.index(before: range.lowerBound)]
            if VocabularyComparison.isWordCharacter(previous) { return false }
        }
        if range.upperBound < text.endIndex, VocabularyComparison.isWordCharacter(text[range.upperBound]) {
            return false
        }
        return true
    }
}

enum VocabularyComparison {
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: locale)
            .precomposedStringWithCanonicalMapping
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .connectorPunctuation:
                true
            default:
                false
            }
        }
    }
}
