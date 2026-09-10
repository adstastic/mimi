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
    private var dictationToggleShortcut: MimiShortcut?
    private var ambientToggleShortcut: MimiShortcut
    private var correctionShortcut: MimiShortcut
    private var pastePresetShortcut: MimiShortcut
    private let onDictationDown: @MainActor () -> Void
    private let onDictationUp: @MainActor () -> Void
    private let onDictationToggle: @MainActor () -> Void
    private let onAmbientToggle: @MainActor () -> Void
    private let onCorrection: @MainActor () -> Void
    private let onPastePresetCycle: @MainActor () -> Void
    private let onCancel: @MainActor () -> Void
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var dictationPressed = false
    private var dictationTogglePressed = false
    private var ambientPressed = false
    private var correctionPressed = false
    private var pastePresetPressed = false
    private var recordingIsActive: @MainActor () -> Bool = { false }

    init(
        dictationShortcut: MimiShortcut,
        dictationToggleShortcut: MimiShortcut? = nil,
        ambientToggleShortcut: MimiShortcut,
        correctionShortcut: MimiShortcut,
        pastePresetShortcut: MimiShortcut = .pastePresetDefault,
        onDictationDown: @escaping @MainActor () -> Void,
        onDictationUp: @escaping @MainActor () -> Void,
        onDictationToggle: @escaping @MainActor () -> Void = {},
        onAmbientToggle: @escaping @MainActor () -> Void,
        onCorrection: @escaping @MainActor () -> Void,
        onPastePresetCycle: @escaping @MainActor () -> Void = {},
        onCancel: @escaping @MainActor () -> Void,
        recordingIsActive: @escaping @MainActor () -> Bool = { false }
    ) {
        self.dictationShortcut = dictationShortcut
        self.ambientToggleShortcut = ambientToggleShortcut
        self.correctionShortcut = correctionShortcut
        self.pastePresetShortcut = pastePresetShortcut
        self.onPastePresetCycle = onPastePresetCycle
        self.onDictationDown = onDictationDown
        self.onDictationUp = onDictationUp
        self.onDictationToggle = onDictationToggle
        self.dictationToggleShortcut = dictationToggleShortcut
        self.onAmbientToggle = onAmbientToggle
        self.onCorrection = onCorrection
        self.onCancel = onCancel
        self.recordingIsActive = recordingIsActive
    }

    var isRunning: Bool { eventTap != nil }

    var statusText: String {
        "Hold: \(dictationShortcut.displayName); Toggle: \(dictationToggleShortcut?.displayName ?? "None"); Ambient: \(ambientToggleShortcut.displayName); Correct: \(correctionShortcut.displayName)"
    }

    func update(
        dictationShortcut: MimiShortcut,
        dictationToggleShortcut: MimiShortcut? = nil,
        ambientToggleShortcut: MimiShortcut,
        correctionShortcut: MimiShortcut,
        pastePresetShortcut: MimiShortcut = .pastePresetDefault
    ) {
        self.dictationShortcut = dictationShortcut
        self.ambientToggleShortcut = ambientToggleShortcut
        self.correctionShortcut = correctionShortcut
        self.pastePresetShortcut = pastePresetShortcut
        self.dictationToggleShortcut = dictationToggleShortcut
        dictationPressed = false
        dictationTogglePressed = false
        ambientPressed = false
        correctionPressed = false
        pastePresetPressed = false
    }

    func start() throws {
        if eventTap != nil { return }

        // NSEvent global monitors omit system shortcuts such as Command-Escape.
        // A listen-only session tap observes them without consuming user input.
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let options = CGEventTapOptions.defaultTap
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: options,
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
        dictationPressed = false
        dictationTogglePressed = false
        ambientPressed = false
        correctionPressed = false
        pastePresetPressed = false
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handle(type: type, event: event)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        if SyntheticKeystroke.isMimi(event) {
            return Unmanaged.passUnretained(event)
        }
        if let nsEvent = NSEvent(cgEvent: event) {
            if type == .keyDown, nsEvent.keyCode == 53, shouldConsumeEscape() {
                Task { @MainActor in onCancel() }
                return nil
            }
            let consumeCorrection = shouldConsumeCorrectionShortcut(nsEvent)
            handle(nsEvent)
            if consumeCorrection { return nil }
        }
        return Unmanaged.passUnretained(event)
    }

    private func shouldConsumeEscape() -> Bool {
        MainActor.assumeIsolated { recordingIsActive() }
    }

    private func shouldConsumeCorrectionShortcut(_ event: NSEvent) -> Bool {
        guard correctionShortcut != dictationShortcut,
              correctionShortcut != dictationToggleShortcut,
              correctionShortcut != ambientToggleShortcut,
              !correctionShortcut.isModifierOnly else { return false }
        switch event.type {
        case .keyDown:
            return matches(event, shortcut: correctionShortcut)
        case .keyUp:
            return Int(event.keyCode) == correctionShortcut.keyCode && correctionPressed
        default:
            return false
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleModifierShortcut(event, shortcut: dictationShortcut, pressed: &dictationPressed, down: onDictationDown, up: onDictationUp)
            if let dictationToggleShortcut, dictationToggleShortcut != dictationShortcut {
                handleModifierToggle(
                    event,
                    shortcut: dictationToggleShortcut,
                    pressed: &dictationTogglePressed,
                    action: onDictationToggle
                )
            }
            if ambientToggleShortcut != dictationShortcut,
               ambientToggleShortcut != dictationToggleShortcut {
                handleModifierToggle(
                    event,
                    shortcut: ambientToggleShortcut,
                    pressed: &ambientPressed,
                    action: onAmbientToggle
                )
            }
            if correctionShortcut != dictationShortcut,
               correctionShortcut != dictationToggleShortcut,
               correctionShortcut != ambientToggleShortcut {
                handleModifierToggle(
                    event,
                    shortcut: correctionShortcut,
                    pressed: &correctionPressed,
                    action: onCorrection
                )
            }
            if isPastePresetShortcutDistinct {
                handleModifierToggle(
                    event,
                    shortcut: pastePresetShortcut,
                    pressed: &pastePresetPressed,
                    action: onPastePresetCycle
                )
            }
        case .keyDown:
            guard !event.isARepeat else { return }
            if event.keyCode == 53 { // Escape.
                if shouldConsumeEscape() {
                    Task { @MainActor in onCancel() }
                }
                return
            }
            if !dictationShortcut.isModifierOnly,
               matches(event, shortcut: dictationShortcut),
               !dictationPressed {
                dictationPressed = true
                Task { @MainActor in onDictationDown() }
                return
            }
            if let dictationToggleShortcut,
               dictationToggleShortcut != dictationShortcut,
               !dictationToggleShortcut.isModifierOnly,
               matches(event, shortcut: dictationToggleShortcut),
               !dictationTogglePressed {
                dictationTogglePressed = true
                Task { @MainActor in onDictationToggle() }
                return
            }
            if ambientToggleShortcut != dictationShortcut,
               ambientToggleShortcut != dictationToggleShortcut,
               !ambientToggleShortcut.isModifierOnly,
               matches(event, shortcut: ambientToggleShortcut) {
                Task { @MainActor in onAmbientToggle() }
                return
            }
            if correctionShortcut != dictationShortcut,
               correctionShortcut != dictationToggleShortcut,
               correctionShortcut != ambientToggleShortcut,
               !correctionShortcut.isModifierOnly,
               matches(event, shortcut: correctionShortcut) {
                correctionPressed = true
                return
            }
            if isPastePresetShortcutDistinct,
               !pastePresetShortcut.isModifierOnly,
               matches(event, shortcut: pastePresetShortcut) {
                Task { @MainActor in onPastePresetCycle() }
                return
            }
        case .keyUp:
            if let dictationToggleShortcut,
               !dictationToggleShortcut.isModifierOnly,
               Int(event.keyCode) == dictationToggleShortcut.keyCode {
                dictationTogglePressed = false
            }
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

    private var isPastePresetShortcutDistinct: Bool {
        pastePresetShortcut != dictationShortcut
            && pastePresetShortcut != dictationToggleShortcut
            && pastePresetShortcut != ambientToggleShortcut
            && pastePresetShortcut != correctionShortcut
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
