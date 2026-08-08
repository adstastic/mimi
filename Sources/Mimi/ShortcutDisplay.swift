import AppKit
import Foundation

extension MimiShortcut {
    static let shortcutModifierMask: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .function]

    var modifierFlags: NSEvent.ModifierFlags {
        Self.normalized(NSEvent.ModifierFlags(rawValue: modifierFlagsRaw))
    }

    static func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(shortcutModifierMask)
    }

    var isModifierOnly: Bool {
        guard let flag = Self.modifierFlag(forKeyCode: keyCode) else { return false }
        return modifierFlags == flag
    }

    var displayName: String {
        if isModifierOnly {
            return Self.modifierKeyName(forKeyCode: keyCode) ?? "Key \(keyCode)"
        }
        return modifierFlags.shortcutSymbols + Self.keyName(forKeyCode: keyCode)
    }

    static func from(event: NSEvent) -> MimiShortcut? {
        switch event.type {
        case .flagsChanged:
            guard let flag = modifierFlag(forKeyCode: Int(event.keyCode)),
                  event.modifierFlags.contains(flag)
            else { return nil }
            return MimiShortcut(keyCode: Int(event.keyCode), modifierFlagsRaw: flag.rawValue)
        case .keyDown:
            let flags = normalized(event.modifierFlags)
            return MimiShortcut(keyCode: Int(event.keyCode), modifierFlagsRaw: flags.rawValue)
        default:
            return nil
        }
    }

    static func modifierFlag(forKeyCode keyCode: Int) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55:
            .command
        case 58, 61:
            .option
        case 59, 62:
            .control
        case 56, 60:
            .shift
        case 63:
            .function
        default:
            nil
        }
    }

    private static func modifierKeyName(forKeyCode keyCode: Int) -> String? {
        switch keyCode {
        case 54:
            "Right Command"
        case 55:
            "Left Command"
        case 58:
            "Left Option"
        case 61:
            "Right Option"
        case 59:
            "Left Control"
        case 62:
            "Right Control"
        case 56:
            "Left Shift"
        case 60:
            "Right Shift"
        case 63:
            "Fn"
        default:
            nil
        }
    }

    private static func keyName(forKeyCode keyCode: Int) -> String {
        switch keyCode {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 22: "6"
        case 23: "5"
        case 24: "="
        case 25: "9"
        case 26: "7"
        case 27: "-"
        case 28: "8"
        case 29: "0"
        case 30: "]"
        case 31: "O"
        case 32: "U"
        case 33: "["
        case 34: "I"
        case 35: "P"
        case 36: "Return"
        case 37: "L"
        case 38: "J"
        case 39: "'"
        case 40: "K"
        case 41: ";"
        case 42: "\\"
        case 43: ","
        case 44: "/"
        case 45: "N"
        case 46: "M"
        case 47: "."
        case 48: "Tab"
        case 49: "Space"
        case 50: "`"
        case 51: "Delete"
        case 53: "Escape"
        case 71: "Clear"
        case 76: "Enter"
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 99: "F3"
        case 100: "F8"
        case 101: "F9"
        case 103: "F11"
        case 105: "F13"
        case 106: "F16"
        case 107: "F14"
        case 109: "F10"
        case 111: "F12"
        case 113: "F15"
        case 114: "Help"
        case 115: "Home"
        case 116: "Page Up"
        case 117: "Forward Delete"
        case 118: "F4"
        case 119: "End"
        case 120: "F2"
        case 121: "Page Down"
        case 122: "F1"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: "Key \(keyCode)"
        }
    }
}

extension PasteSettings {
    /// e.g. "C → paste → Return".
    var keystrokeSummary: String {
        [prePasteKeystroke?.displayName, "paste", postPasteKeystroke?.displayName]
            .compactMap { $0 }
            .joined(separator: " → ")
    }
}

private extension NSEvent.ModifierFlags {
    var shortcutSymbols: String {
        var symbols = ""
        if contains(.control) { symbols += "⌃" }
        if contains(.option) { symbols += "⌥" }
        if contains(.shift) { symbols += "⇧" }
        if contains(.command) { symbols += "⌘" }
        if contains(.function) { symbols += "fn " }
        return symbols
    }
}
