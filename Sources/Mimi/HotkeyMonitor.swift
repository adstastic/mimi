import AppKit
import CoreGraphics
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

    private var dictationShortcut: MimiShortcut
    private var ambientToggleShortcut: MimiShortcut
    private var correctionShortcut: MimiShortcut
    private let onDictationDown: @MainActor () -> Void
    private let onDictationUp: @MainActor () -> Void
    private let onAmbientToggle: @MainActor () -> Void
    private let onCorrection: @MainActor () -> Void
    private let onCancel: @MainActor () -> Void
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private(set) var usesActiveEventTap = false
    private var dictationPressed = false
    private var ambientPressed = false
    private var correctionPressed = false

    init(
        dictationShortcut: MimiShortcut,
        ambientToggleShortcut: MimiShortcut,
        correctionShortcut: MimiShortcut,
        onDictationDown: @escaping @MainActor () -> Void,
        onDictationUp: @escaping @MainActor () -> Void,
        onAmbientToggle: @escaping @MainActor () -> Void,
        onCorrection: @escaping @MainActor () -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.dictationShortcut = dictationShortcut
        self.ambientToggleShortcut = ambientToggleShortcut
        self.correctionShortcut = correctionShortcut
        self.onDictationDown = onDictationDown
        self.onDictationUp = onDictationUp
        self.onAmbientToggle = onAmbientToggle
        self.onCorrection = onCorrection
        self.onCancel = onCancel
    }

    var statusText: String {
        "Dictation: \(dictationShortcut.displayName); Ambient: \(ambientToggleShortcut.displayName); Correct: \(correctionShortcut.displayName)"
    }

    func update(
        dictationShortcut: MimiShortcut,
        ambientToggleShortcut: MimiShortcut,
        correctionShortcut: MimiShortcut
    ) {
        self.dictationShortcut = dictationShortcut
        self.ambientToggleShortcut = ambientToggleShortcut
        self.correctionShortcut = correctionShortcut
        dictationPressed = false
        ambientPressed = false
        correctionPressed = false
    }

    func start() throws {
        if eventTap != nil { return }

        // NSEvent global monitors omit system shortcuts such as Command-Escape.
        // A listen-only session tap observes them without consuming user input.
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw HotkeyError.monitorCreationFailed
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        usesActiveEventTap = true
    }

    func stop() {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        eventTap = nil
        eventTapSource = nil
        usesActiveEventTap = false
        dictationPressed = false
        ambientPressed = false
        correctionPressed = false
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handle(type: type, event: event)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type != .keyDown,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.keyCode != 53 else {
            if let nsEvent = NSEvent(cgEvent: event) {
                handle(nsEvent)
            }
            return nil
        }
        handle(nsEvent)
        return Unmanaged.passUnretained(event)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleModifierShortcut(event, shortcut: dictationShortcut, pressed: &dictationPressed, down: onDictationDown, up: onDictationUp)
            if ambientToggleShortcut != dictationShortcut {
                handleModifierToggle(
                    event,
                    shortcut: ambientToggleShortcut,
                    pressed: &ambientPressed,
                    action: onAmbientToggle
                )
            }
            if correctionShortcut != dictationShortcut,
               correctionShortcut != ambientToggleShortcut {
                handleModifierToggle(
                    event,
                    shortcut: correctionShortcut,
                    pressed: &correctionPressed,
                    action: onCorrection
                )
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
                return
            }
            if correctionShortcut != dictationShortcut,
               correctionShortcut != ambientToggleShortcut,
               !correctionShortcut.isModifierOnly,
               matches(event, shortcut: correctionShortcut) {
                correctionPressed = true
            }
        case .keyUp:
            if !dictationShortcut.isModifierOnly,
               Int(event.keyCode) == dictationShortcut.keyCode,
               dictationPressed {
                dictationPressed = false
                Task { @MainActor in onDictationUp() }
            }
            if !correctionShortcut.isModifierOnly,
               Int(event.keyCode) == correctionShortcut.keyCode,
               correctionPressed {
                correctionPressed = false
                Task { @MainActor in onCorrection() }
            }
        default:
            break
        }
    }

    private func handleModifierShortcut(
        _ event: NSEvent,
        shortcut: MimiShortcut,
        pressed: inout Bool,
        down: @escaping @MainActor () -> Void,
        up: @escaping @MainActor () -> Void
    ) {
        guard shortcut.isModifierOnly,
              Int(event.keyCode) == shortcut.keyCode,
              let flag = MimiShortcut.modifierFlag(forKeyCode: shortcut.keyCode)
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

    private func handleModifierToggle(
        _ event: NSEvent,
        shortcut: MimiShortcut,
        pressed: inout Bool,
        action: @escaping @MainActor () -> Void
    ) {
        guard shortcut.isModifierOnly,
              Int(event.keyCode) == shortcut.keyCode,
              let flag = MimiShortcut.modifierFlag(forKeyCode: shortcut.keyCode)
        else { return }

        let isDown = event.modifierFlags.contains(flag)
        if isDown, !pressed {
            pressed = true
            Task { @MainActor in action() }
        } else if !isDown {
            pressed = false
        }
    }

    private func matches(_ event: NSEvent, shortcut: MimiShortcut) -> Bool {
        Int(event.keyCode) == shortcut.keyCode
            && MimiShortcut.normalized(event.modifierFlags) == shortcut.modifierFlags
    }
}
