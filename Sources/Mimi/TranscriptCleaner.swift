import Foundation

enum TranscriptCleaner {
    private static let filler = #"(?:[Uu]m+|[Uu]h+|[Ee]rm+|[Aa]h+)"#
    private static let leftBoundary = #"(?<![\p{L}\p{N}_@#$`/\\.\-‐‑‒–—―])"#
    private static let rightBoundary = #"(?![\p{L}\p{N}_@#$`/\\\-‐‑‒–—―]|\.[\p{L}\p{N}])"#
    private static let quotedText = try! NSRegularExpression(
        pattern: #"`[^`]*`|"[^\"]*"|“[^”]*”|‘[^’]*’|(?<![\p{L}\p{N}])'[^']+'(?![\p{L}\p{N}])"#
    )
    private static let unmatchedOpeningQuote = try! NSRegularExpression(pattern: #"["“‘]"#)

    static func clean(_ text: String) -> String {
        var (cleaned, protectedText) = protectingQuotedText(in: text)
        let sentencePrefix = #"(^[ \t]*|[.!?][ \t]+|(?:\r\n|[\r\n])[ \t]*)"#

        cleaned = replace(
            sentencePrefix + filler + rightBoundary + #"[.!?…](?:[ \t]+|(?=\r\n|[\r\n])|$)"#,
            in: cleaned,
            with: "$1"
        )
        cleaned = replace(
            #"[ \t]*,[ \t]*"# + filler + rightBoundary + #"(?:[ \t]*,)?"#,
            in: cleaned,
            with: ""
        )
        cleaned = replace(
            leftBoundary + filler + rightBoundary + #"[ \t]*,[ \t]*"#,
            in: cleaned,
            with: ""
        )
        cleaned = replace(
            #"[ \t]+"# + filler + rightBoundary + #"(?=[.!?…])"#,
            in: cleaned,
            with: ""
        )
        cleaned = replace(
            #"[ \t]+"# + filler + rightBoundary + #"(?=[ \t]+|$)"#,
            in: cleaned,
            with: ""
        )
        cleaned = replace(leftBoundary + filler + rightBoundary, in: cleaned, with: "")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        for (placeholder, original) in protectedText.reversed() {
            cleaned = cleaned.replacingOccurrences(of: placeholder, with: original)
        }
        return cleaned
    }

    private static func protectingQuotedText(in text: String) -> (String, [(String, String)]) {
        let source = text as NSString
        let matches = quotedText.matches(in: text, range: NSRange(location: 0, length: source.length))
        var result = text
        var protectedText: [(String, String)] = []
        for (index, match) in matches.enumerated().reversed() {
            let placeholder = "\u{E000}\(index)\u{E001}"
            let original = source.substring(with: match.range)
            result = (result as NSString).replacingCharacters(in: match.range, with: placeholder)
            protectedText.append((placeholder, original))
        }

        let remaining = result as NSString
        if let opening = unmatchedOpeningQuote.firstMatch(
            in: result,
            range: NSRange(location: 0, length: remaining.length)
        ) {
            let range = NSRange(location: opening.range.location, length: remaining.length - opening.range.location)
            let placeholder = "\u{E000}\(matches.count)\u{E001}"
            protectedText.append((placeholder, remaining.substring(with: range)))
            result = remaining.replacingCharacters(in: range, with: placeholder)
        }
        return (result, protectedText)
    }

    private static func replace(_ pattern: String, in text: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}
