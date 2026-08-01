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

    func insert(_ text: String, pressReturn: Bool, enterDelayMilliseconds: Int) async throws {
        try pasteViaClipboard(text)

        if pressReturn {
            try await sleep(milliseconds: enterDelayMilliseconds)
            try pressReturnKey()
        }
    }

    func copyToClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw InsertError.pasteboardWriteFailed
        }
    }

    func pressReturn() throws {
        try pressReturnKey()
    }

    private func pasteViaClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw InsertError.pasteboardWriteFailed
        }

        try sendKey(virtualKey: 9, flags: .maskCommand) // V
    }

    private func pressReturnKey() throws {
        try sendKey(virtualKey: 36, flags: [])
    }

    private func sendKey(virtualKey: CGKeyCode, flags: CGEventFlags) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
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
