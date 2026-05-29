import AppKit
import Foundation

final class HotkeyMonitor {
    enum HotkeyError: LocalizedError {
        case monitorCreationFailed

        var errorDescription: String? {
            switch self {
            case .monitorCreationFailed:
                "Could not create global keyboard monitor. Check Input Monitoring permission."
            }
        }
    }

    private var dictationShortcut: SokkiShortcut
    private var ambientToggleShortcut: SokkiShortcut
    private let onDictationDown: @MainActor () -> Void
    private let onDictationUp: @MainActor () -> Void
    private let onAmbientToggle: @MainActor () -> Void
    private let onCancel: @MainActor () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var dictationPressed = false
    private var ambientPressed = false

    init(
        dictationShortcut: SokkiShortcut,
        ambientToggleShortcut: SokkiShortcut,
        onDictationDown: @escaping @MainActor () -> Void,
        onDictationUp: @escaping @MainActor () -> Void,
        onAmbientToggle: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.dictationShortcut = dictationShortcut
        self.ambientToggleShortcut = ambientToggleShortcut
        self.onDictationDown = onDictationDown
        self.onDictationUp = onDictationUp
        self.onAmbientToggle = onAmbientToggle
        self.onCancel = onCancel
    }

    var statusText: String {
        "Dictation: \(dictationShortcut.displayName); Ambient: \(ambientToggleShortcut.displayName)"
    }

    func update(dictationShortcut: SokkiShortcut, ambientToggleShortcut: SokkiShortcut) {
        self.dictationShortcut = dictationShortcut
        self.ambientToggleShortcut = ambientToggleShortcut
        dictationPressed = false
        ambientPressed = false
    }

    func start() throws {
        if globalMonitor != nil || localMonitor != nil { return }

        // Single modifier keys can't use macOS' normal hotkey API, and hold-to-dictate
        // needs key-up. Monitor events and always pass them through.
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        }

        guard globalMonitor != nil || localMonitor != nil else {
            throw HotkeyError.monitorCreationFailed
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        dictationPressed = false
        ambientPressed = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleModifierShortcut(event, shortcut: dictationShortcut, pressed: &dictationPressed, down: onDictationDown, up: onDictationUp)
            if ambientToggleShortcut != dictationShortcut {
                handleModifierToggle(event, shortcut: ambientToggleShortcut)
            }
        case .keyDown:
            guard !event.isARepeat else { return }
            if event.keyCode == 53 { // Escape.
                Task { @MainActor in onCancel() }
                return
            }
            if !dictationShortcut.isModifierOnly,
               matches(event, shortcut: dictationShortcut),
               !dictationPressed {
                dictationPressed = true
                Task { @MainActor in onDictationDown() }
                return
            }
            if ambientToggleShortcut != dictationShortcut,
               !ambientToggleShortcut.isModifierOnly,
               matches(event, shortcut: ambientToggleShortcut) {
                Task { @MainActor in onAmbientToggle() }
            }
        case .keyUp:
            if !dictationShortcut.isModifierOnly,
               Int(event.keyCode) == dictationShortcut.keyCode,
               dictationPressed {
                dictationPressed = false
                Task { @MainActor in onDictationUp() }
            }
        default:
            break
        }
    }

    private func handleModifierShortcut(
        _ event: NSEvent,
        shortcut: SokkiShortcut,
        pressed: inout Bool,
        down: @escaping @MainActor () -> Void,
        up: @escaping @MainActor () -> Void
    ) {
        guard shortcut.isModifierOnly,
              Int(event.keyCode) == shortcut.keyCode,
              let flag = SokkiShortcut.modifierFlag(forKeyCode: shortcut.keyCode)
        else { return }

        let isDown = event.modifierFlags.contains(flag)
        if isDown, !pressed {
            pressed = true
            Task { @MainActor in down() }
        } else if !isDown, pressed {
            pressed = false
            Task { @MainActor in up() }
        }
    }

    private func handleModifierToggle(_ event: NSEvent, shortcut: SokkiShortcut) {
        guard shortcut.isModifierOnly,
              Int(event.keyCode) == shortcut.keyCode,
              let flag = SokkiShortcut.modifierFlag(forKeyCode: shortcut.keyCode)
        else { return }

        let isDown = event.modifierFlags.contains(flag)
        if isDown, !ambientPressed {
            ambientPressed = true
            Task { @MainActor in onAmbientToggle() }
        } else if !isDown {
            ambientPressed = false
        }
    }

    private func matches(_ event: NSEvent, shortcut: SokkiShortcut) -> Bool {
        Int(event.keyCode) == shortcut.keyCode
            && SokkiShortcut.normalized(event.modifierFlags) == shortcut.modifierFlags
    }
}
