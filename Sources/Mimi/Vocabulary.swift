import Foundation

public struct VocabularyEntry: Codable, Equatable, Sendable {
    public var from: [String]
    public var to: String

    public init(from: [String], to: String) {
        self.from = from
        self.to = to
    }
}

enum VocabularyValidationError: LocalizedError, Equatable {
    case emptySource
    case emptyTarget
    case conflictingPhrase(String, firstTarget: String, secondTarget: String)

    var errorDescription: String? {
        switch self {
        case .emptySource:
            "Vocabulary source phrases cannot be empty."
        case .emptyTarget:
            "Vocabulary target cannot be empty."
        case .conflictingPhrase(let phrase, let first, let second):
            "“\(phrase)” is already mapped to both “\(first)” and “\(second)”."
        }
    }
}

enum VocabularyValidator {
    static func validate(_ entries: [VocabularyEntry]) -> VocabularyValidationError? {
        var owners: [String: (entryIndex: Int, target: String)] = [:]

        for (entryIndex, entry) in entries.enumerated() {
            let target = entry.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return .emptyTarget }
            var ownKeys: Set<String> = []

            for source in [target] + entry.from {
                let phrase = source.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !phrase.isEmpty else { return .emptySource }
                let key = VocabularyComparison.key(phrase)
                guard !key.isEmpty, ownKeys.insert(key).inserted else { continue }

                if let owner = owners[key], owner.entryIndex != entryIndex {
                    return .conflictingPhrase(
                        phrase,
                        firstTarget: owner.target,
                        secondTarget: target
                    )
                }
                owners[key] = (entryIndex, target)
            }
        }
        return nil
    }
}

struct VocabularyCorrectionSuggestion: Hashable {
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
        guard !heard.isEmpty, !written.isEmpty,
              isCompactSingleEdit(heard: heard, written: written) else { return nil }
        return VocabularyCorrectionSuggestion(heard: heard, written: written)
    }

    static func inferAll(source: String, corrected: String) -> [VocabularyCorrectionSuggestion] {
        guard source != corrected else { return [] }
        let sourceTokens = wordTokens(in: source)
        let correctedTokens = wordTokens(in: corrected)
        let anchors = commonAnchors(sourceTokens, correctedTokens)

        var sourceStart = source.startIndex
        var correctedStart = corrected.startIndex
        var suggestions: [VocabularyCorrectionSuggestion] = []
        var seen: Set<String> = []

        func appendSuggestion(sourceEnd: String.Index, correctedEnd: String.Index) {
            let sourceSegment = String(source[sourceStart ..< sourceEnd])
            guard let suggestion = infer(
                source: sourceSegment,
                corrected: String(corrected[correctedStart ..< correctedEnd])
            ), !spansWholeSentence(
                sourceSegment,
                startsAtTextStart: sourceStart == source.startIndex,
                endsAtTextEnd: sourceEnd == source.endIndex
            ) else { return }
            let key = VocabularyComparison.key(suggestion.heard)
                + "\u{0}"
                + VocabularyComparison.key(suggestion.written)
            if seen.insert(key).inserted {
                suggestions.append(suggestion)
            }
        }

        for anchor in anchors {
            let sourceToken = sourceTokens[anchor.source]
            let correctedToken = correctedTokens[anchor.corrected]
            appendSuggestion(
                sourceEnd: sourceToken.range.lowerBound,
                correctedEnd: correctedToken.range.lowerBound
            )
            sourceStart = sourceToken.range.upperBound
            correctedStart = correctedToken.range.upperBound
        }
        appendSuggestion(sourceEnd: source.endIndex, correctedEnd: corrected.endIndex)
        return suggestions
    }

    private struct WordToken {
        let text: String
        let range: Range<String.Index>
        let leadingSeparator: String
    }

    private struct Anchor {
        let source: Int
        let corrected: Int
    }

    private static func wordTokens(in text: String) -> [WordToken] {
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex,
                  !VocabularyComparison.isWordCharacter(text[index]) {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex,
                  VocabularyComparison.isWordCharacter(text[index]) {
                index = text.index(after: index)
            }
            ranges.append(start ..< index)
        }

        return ranges.indices.map { index in
            let range = ranges[index]
            let previousEnd = index == ranges.startIndex ? text.startIndex : ranges[index - 1].upperBound
            return WordToken(
                text: String(text[range]),
                range: range,
                leadingSeparator: String(text[previousEnd ..< range.lowerBound])
            )
        }
    }

    private static func commonAnchors(
        _ source: [WordToken],
        _ corrected: [WordToken]
    ) -> [Anchor] {
        guard !source.isEmpty, !corrected.isEmpty else { return [] }
        var lengths = Array(
            repeating: Array(repeating: 0, count: corrected.count + 1),
            count: source.count + 1
        )

        for sourceIndex in source.indices.reversed() {
            for correctedIndex in corrected.indices.reversed() {
                if tokensMatch(source[sourceIndex], corrected[correctedIndex]) {
                    lengths[sourceIndex][correctedIndex] = lengths[sourceIndex + 1][correctedIndex + 1] + 1
                } else {
                    lengths[sourceIndex][correctedIndex] = max(
                        lengths[sourceIndex + 1][correctedIndex],
                        lengths[sourceIndex][correctedIndex + 1]
                    )
                }
            }
        }

        var anchors: [Anchor] = []
        var sourceIndex = 0
        var correctedIndex = 0
        while sourceIndex < source.count, correctedIndex < corrected.count {
            if tokensMatch(source[sourceIndex], corrected[correctedIndex]) {
                anchors.append(Anchor(source: sourceIndex, corrected: correctedIndex))
                sourceIndex += 1
                correctedIndex += 1
            } else if lengths[sourceIndex + 1][correctedIndex] >= lengths[sourceIndex][correctedIndex + 1] {
                sourceIndex += 1
            } else {
                correctedIndex += 1
            }
        }
        return anchors
    }

    private static func tokensMatch(_ lhs: WordToken, _ rhs: WordToken) -> Bool {
        lhs.text == rhs.text
            && containsWhitespace(lhs.leadingSeparator) == containsWhitespace(rhs.leadingSeparator)
    }

    private static func containsWhitespace(_ text: String) -> Bool {
        text.contains(where: \.isWhitespace)
    }

    private static func spansWholeSentence(
        _ segment: String,
        startsAtTextStart: Bool,
        endsAtTextEnd: Bool
    ) -> Bool {
        let terminators: Set<Character> = [".", "?", "!"]
        let tokens = wordTokens(in: segment)
        guard segment.contains(where: terminators.contains),
              let first = tokens.first,
              let last = tokens.last else { return false }
        let leading = segment[segment.startIndex ..< first.range.lowerBound]
        let trailing = segment[last.range.upperBound ..< segment.endIndex]
        let startsAtSentenceBoundary = startsAtTextStart || leading.contains(where: terminators.contains)
        let endsAtSentenceBoundary = endsAtTextEnd || trailing.contains(where: terminators.contains)
        return startsAtSentenceBoundary && endsAtSentenceBoundary
    }

    private static func isCompactSingleEdit(heard: String, written: String) -> Bool {
        guard heard.count <= 60, written.count <= 60,
              !heard.contains("\n"), !written.contains("\n") else { return false }
        let heardWordCount = wordCount(in: heard)
        let writtenWordCount = wordCount(in: written)
        return (1 ... 3).contains(heardWordCount) && (1 ... 3).contains(writtenWordCount)
    }

    private static func wordCount(in text: String) -> Int {
        var count = 0
        var insideWord = false
        for character in text {
            if VocabularyComparison.isWordCharacter(character) {
                if !insideWord { count += 1 }
                insideWord = true
            } else {
                insideWord = false
            }
        }
        return count
    }
}

enum VocabularyEntryUpdater {
    static func addingCorrections(
        _ corrections: [VocabularyCorrectionSuggestion],
        to entries: [VocabularyEntry]
    ) throws -> [VocabularyEntry] {
        try corrections.reduce(entries) { entries, correction in
            try addingCorrection(
                heard: correction.heard,
                written: correction.written,
                to: entries
            )
        }
    }

    static func addingCorrection(
        heard: String,
        written: String,
        to entries: [VocabularyEntry]
    ) throws -> [VocabularyEntry] {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = written.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { throw VocabularyValidationError.emptySource }
        guard !written.isEmpty else { throw VocabularyValidationError.emptyTarget }

        var updated = entries
        let writtenKey = VocabularyComparison.key(written)
        if let index = updated.firstIndex(where: {
            VocabularyComparison.key($0.to.trimmingCharacters(in: .whitespacesAndNewlines)) == writtenKey
        }) {
            let existingKeys = Set(([updated[index].to] + updated[index].from).map(VocabularyComparison.key))
            if !existingKeys.contains(VocabularyComparison.key(heard)) {
                updated[index].from.append(heard)
            }
        } else {
            updated.append(VocabularyEntry(from: [heard], to: written))
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

    static func contains(phrase: String, in text: String) -> Bool {
        let key = VocabularyComparison.key(phrase.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty else { return false }
        return !matches(for: Phrase(key: key, replacement: ""), in: text).isEmpty
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

        for (entryIndex, entry) in entries.enumerated() {
            let replacement = entry.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !replacement.isEmpty else { continue }

            for source in [replacement] + entry.from {
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
