import AppKit
import Foundation

/// Marks keystrokes Mimi posts itself so HotkeyMonitor never reads them back as user shortcuts.
/// Posted events inherit physically-held modifiers, so an untagged synthetic "C" can look like ⌃⌥C.
enum SyntheticKeystroke {
    static let tag: Int64 = 0x4D_49_4D_49 // "MIMI"

    static func isMimi(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == tag
    }
}

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

    func insert(
        _ text: String,
        prePasteKeystroke: MimiShortcut?,
        prePasteDelayMilliseconds: Int,
        postPasteKeystroke: MimiShortcut?,
        postPasteDelayMilliseconds: Int
    ) async throws {
        try copyToClipboard(text)
        if let prePasteKeystroke {
            try press(prePasteKeystroke)
            try await sleep(milliseconds: prePasteDelayMilliseconds)
        }
        try pasteClipboard()
        if let postPasteKeystroke {
            try await sleep(milliseconds: postPasteDelayMilliseconds)
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

    private func press(_ keystroke: MimiShortcut) throws {
        try sendKey(
            virtualKey: CGKeyCode(keystroke.keyCode),
            flags: CGEventFlags(rawValue: UInt64(keystroke.modifierFlagsRaw))
        )
    }

    private func pasteClipboard() throws {
        try sendKey(virtualKey: 9, flags: .maskCommand) // V
    }

    private func sendKey(virtualKey: CGKeyCode, flags: CGEventFlags) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        else { throw InsertError.eventSourceUnavailable }

        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: SyntheticKeystroke.tag)
        up.setIntegerValueField(.eventSourceUserData, value: SyntheticKeystroke.tag)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func sleep(milliseconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
    }
}
