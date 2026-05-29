import ApplicationServices
import Foundation

final class HotkeyMonitor {
    enum HotkeyError: LocalizedError {
        case accessibilityNotTrusted
        case eventTapCreationFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityNotTrusted:
                "Accessibility permission is required for the global hotkey."
            case .eventTapCreationFailed:
                "Could not create global keyboard event tap."
            }
        }
    }

    private let keyCode: Int64
    private let onKeyDown: @MainActor () -> Void
    private let onKeyUp: @MainActor () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pressed = false

    init(keyCode: Int, onKeyDown: @escaping @MainActor () -> Void, onKeyUp: @escaping @MainActor () -> Void) {
        self.keyCode = Int64(keyCode)
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
    }

    func start() throws {
        if eventTap != nil { return }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)
            | (1 << CGEventType.tapDisabledByUserInput.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyError.eventTapCreationFailed
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw HotkeyError.eventTapCreationFailed
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        pressed = false
    }

    private nonisolated static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        return monitor.handle(type: type, event: event)
    }

    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor in
                if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard eventKeyCode == keyCode else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            let isDown = event.flags.contains(.maskAlternate)
            Task { @MainActor in
                if isDown, !pressed {
                    pressed = true
                    onKeyDown()
                } else if !isDown, pressed {
                    pressed = false
                    onKeyUp()
                }
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            guard !autorepeat else { return Unmanaged.passUnretained(event) }
            Task { @MainActor in
                guard !pressed else { return }
                pressed = true
                onKeyDown()
            }
            return Unmanaged.passUnretained(event)
        case .keyUp:
            Task { @MainActor in
                guard pressed else { return }
                pressed = false
                onKeyUp()
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
