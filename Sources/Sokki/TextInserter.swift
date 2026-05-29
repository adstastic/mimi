import AppKit
import Foundation

@MainActor
final class TextInserter {
    enum InsertError: LocalizedError {
        case eventSourceUnavailable
        case pasteboardWriteFailed

        var errorDescription: String? {
            switch self {
            case .eventSourceUnavailable:
                "Could not create keyboard event source."
            case .pasteboardWriteFailed:
                "Could not write transcript to pasteboard."
            }
        }
    }

    func insert(_ text: String, autoEnterMode: AutoEnterMode, enterDelayMilliseconds: Int) async throws {
        try pasteViaClipboard(text)

        if autoEnterMode == .always {
            try await sleep(milliseconds: enterDelayMilliseconds)
            try pressReturn()
        }
    }

    func retryWithoutClipboard(_ text: String) throws {
        try typeUnicode(text)
    }

    func copyToClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw InsertError.pasteboardWriteFailed
        }
    }

    private func pasteViaClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems ?? []

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw InsertError.pasteboardWriteFailed
        }

        try sendKey(virtualKey: 9, flags: .maskCommand) // V

        Task { @MainActor in
            try? await self.sleep(milliseconds: 400)
            pasteboard.clearContents()
            if !previousItems.isEmpty {
                pasteboard.writeObjects(previousItems)
            }
        }
    }

    private func typeUnicode(_ text: String) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        guard source != nil else { throw InsertError.eventSourceUnavailable }

        let units = Array(text.utf16)
        var index = units.startIndex
        while index < units.endIndex {
            let end = units.index(index, offsetBy: min(20, units.distance(from: index, to: units.endIndex)))
            var chunk = Array(units[index..<end])

            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { throw InsertError.eventSourceUnavailable }

            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)

            index = end
        }
    }

    private func pressReturn() throws {
        try sendKey(virtualKey: 36, flags: [])
    }

    private func sendKey(virtualKey: CGKeyCode, flags: CGEventFlags) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { throw InsertError.eventSourceUnavailable }

        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func sleep(milliseconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }
}
