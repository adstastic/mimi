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

    func insert(_ text: String, postPasteKeystroke: MimiShortcut?, delayMilliseconds: Int) async throws {
        try pasteViaClipboard(text)

        if let postPasteKeystroke {
            try await sleep(milliseconds: delayMilliseconds)
            try press(postPasteKeystroke)
        }
    }

    func copyToClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw InsertError.pasteboardWriteFailed
        }
    }

    func press(_ keystroke: MimiShortcut) throws {
        try sendKey(
            virtualKey: CGKeyCode(keystroke.keyCode),
            flags: CGEventFlags(rawValue: UInt64(keystroke.modifierFlagsRaw))
        )
    }

    private func pasteViaClipboard(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw InsertError.pasteboardWriteFailed
        }

        try sendKey(virtualKey: 9, flags: .maskCommand) // V
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
