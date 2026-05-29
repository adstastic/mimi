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

    private let keyCode: UInt16
    private let onKeyDown: @MainActor () -> Void
    private let onKeyUp: @MainActor () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pressed = false

    init(keyCode: Int, onKeyDown: @escaping @MainActor () -> Void, onKeyUp: @escaping @MainActor () -> Void) {
        self.keyCode = UInt16(keyCode)
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
    }

    func start() throws {
        if globalMonitor != nil || localMonitor != nil { return }

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
        pressed = false
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == keyCode else { return }

        switch event.type {
        case .flagsChanged:
            let isDown = event.modifierFlags.contains(.command)
            if isDown, !pressed {
                pressed = true
                Task { @MainActor in onKeyDown() }
            } else if !isDown, pressed {
                pressed = false
                Task { @MainActor in onKeyUp() }
            }
        case .keyDown:
            guard !event.isARepeat, !pressed else { return }
            pressed = true
            Task { @MainActor in onKeyDown() }
        case .keyUp:
            guard pressed else { return }
            pressed = false
            Task { @MainActor in onKeyUp() }
        default:
            break
        }
    }
}
