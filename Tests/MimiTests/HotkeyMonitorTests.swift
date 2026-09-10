import CoreGraphics
import XCTest
@testable import Mimi

@MainActor
final class HotkeyMonitorTests: XCTestCase {
    func testHoldAndToggleDispatchIndependentlyForKeysAndModifiers() async throws {
        let shortcuts: [(MimiShortcut, MimiShortcut)] = [
            (.rightCommand, .legacySingleKey(keyCode: 62)),
            (MimiShortcut(keyCode: 4, modifierFlagsRaw: NSEvent.ModifierFlags.control.rawValue),
             MimiShortcut(keyCode: 2, modifierFlagsRaw: NSEvent.ModifierFlags.option.rawValue))
        ]
        for (hold, toggle) in shortcuts {
            var actions: [String] = []
            let handled = expectation(description: "Hold down/up and two toggle presses")
            handled.expectedFulfillmentCount = 4
            let monitor = HotkeyMonitor(
                dictationShortcut: hold,
                dictationToggleShortcut: toggle,
                ambientToggleShortcut: .ambientToggleDefault,
                correctionShortcut: .correctionDefault,
                onDictationDown: { actions.append("hold.down"); handled.fulfill() },
                onDictationUp: { actions.append("hold.up"); handled.fulfill() },
                onDictationToggle: { actions.append("toggle"); handled.fulfill() },
                onAmbientToggle: {},
                onCorrection: {},
                onCancel: {}
            )
            try send(hold, down: true, to: monitor)
            try send(hold, down: false, to: monitor)
            for _ in 0..<2 {
                try send(toggle, down: true, to: monitor)
                try send(toggle, down: true, to: monitor)
                try send(toggle, down: true, isRepeat: true, to: monitor)
                try send(toggle, down: false, to: monitor)
            }
            await fulfillment(of: [handled], timeout: 1)
            XCTAssertEqual(actions.filter { $0 == "hold.down" }.count, 1)
            XCTAssertEqual(actions.filter { $0 == "hold.up" }.count, 1)
            XCTAssertEqual(actions.filter { $0 == "toggle" }.count, 2)

            monitor.update(
                dictationShortcut: hold,
                dictationToggleShortcut: nil,
                ambientToggleShortcut: .ambientToggleDefault,
                correctionShortcut: .correctionDefault
            )
            try send(toggle, down: true, to: monitor)
            try send(toggle, down: false, to: monitor)
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(actions.count, 4, "Clearing toggle must disable it")
        }
    }

    func testShortcutConflictsKeepHoldThenTogglePriority() async throws {
        for toggle in [MimiShortcut.rightCommand, .ambientToggleDefault, .correctionDefault, .pastePresetDefault] {
            var actions: [String] = []
            let handled = expectation(description: "Only highest-priority shortcut fires")
            let monitor = HotkeyMonitor(
                dictationShortcut: .rightCommand,
                dictationToggleShortcut: toggle,
                ambientToggleShortcut: .ambientToggleDefault,
                correctionShortcut: .correctionDefault,
                onDictationDown: { actions.append("hold"); handled.fulfill() },
                onDictationUp: {},
                onDictationToggle: { actions.append("toggle"); handled.fulfill() },
                onAmbientToggle: { actions.append("ambient") },
                onCorrection: { actions.append("correction") },
                onPastePresetCycle: { actions.append("preset") },
                onCancel: {}
            )
            try send(toggle, down: true, to: monitor)
            try send(toggle, down: false, to: monitor)
            await fulfillment(of: [handled], timeout: 1)
            XCTAssertEqual(actions, [toggle == .rightCommand ? "hold" : "toggle"])
        }
    }

    private func send(_ shortcut: MimiShortcut, down: Bool, isRepeat: Bool = false, to monitor: HotkeyMonitor) throws {
        let event = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(shortcut.keyCode),
            keyDown: down
        ))
        event.type = shortcut.isModifierOnly ? .flagsChanged : (down ? .keyDown : .keyUp)
        event.flags = shortcut.isModifierOnly && !down ? [] : CGEventFlags(rawValue: UInt64(shortcut.modifierFlagsRaw))
        event.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
        _ = monitor.handle(type: event.type, event: event)
    }

    func testCorrectionShortcutEventsAreConsumed() throws {
        let monitor = HotkeyMonitor(
            dictationShortcut: .rightCommand,
            ambientToggleShortcut: .ambientToggleDefault,
            correctionShortcut: .correctionDefault,
            onDictationDown: {},
            onDictationUp: {},
            onAmbientToggle: {},
            onCorrection: {},
            onCancel: {}
        )
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true))
        let keyUp = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false))
        keyDown.flags = [.maskControl, .maskAlternate]
        keyUp.flags = [.maskControl, .maskAlternate]

        XCTAssertNil(monitor.handle(type: .keyDown, event: keyDown))
        XCTAssertNil(monitor.handle(type: .keyUp, event: keyUp))
    }

    func testCorrectionShortcutInvokesAfterKeyRelease() async throws {
        guard CGPreflightListenEventAccess(), CGPreflightPostEventAccess() else {
            throw XCTSkip("Global keyboard test requires Input Monitoring and Accessibility permissions.")
        }

        var correctionCount = 0
        let corrected = expectation(description: "Correction shortcut invokes correction")
        let monitor = HotkeyMonitor(
            dictationShortcut: .rightCommand,
            ambientToggleShortcut: .ambientToggleDefault,
            correctionShortcut: .correctionDefault,
            onDictationDown: {},
            onDictationUp: {},
            onAmbientToggle: {},
            onCorrection: {
                correctionCount += 1
                corrected.fulfill()
            },
            onCancel: {}
        )
        try monitor.start()
        defer { monitor.stop() }

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true))
        let keyUp = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false))
        keyDown.flags = [.maskControl, .maskAlternate]
        keyUp.flags = [.maskControl, .maskAlternate]
        keyDown.post(tap: .cghidEventTap)

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(correctionCount, 0)

        keyUp.post(tap: .cghidEventTap)
        await fulfillment(of: [corrected], timeout: 1)
        XCTAssertEqual(correctionCount, 1)
    }

    func testEscapeWhileRecordingInvokesCancelWithoutLeakingToFocusedApp() async throws {
        guard CGPreflightListenEventAccess(), CGPreflightPostEventAccess() else {
            throw XCTSkip("Global keyboard test requires Input Monitoring and Accessibility permissions.")
        }

        let cancelled = expectation(description: "Escape cancels recording")
        let keySink = expectation(description: "Escape is not delivered downstream")
        keySink.isInverted = true
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { keySink.fulfill() }
            return event
        }
        let monitor = HotkeyMonitor(
            dictationShortcut: .rightCommand,
            ambientToggleShortcut: .ambientToggleDefault,
            correctionShortcut: .correctionDefault,
            onDictationDown: {},
            onDictationUp: {},
            onAmbientToggle: {},
            onCorrection: {},
            onCancel: { cancelled.fulfill() },
            recordingIsActive: { true }
        )
        try monitor.start()
        defer {
            monitor.stop()
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true))
        let keyUp = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false))
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        await fulfillment(of: [cancelled, keySink], timeout: 1)
    }

    func testEscapeOutsideRecordingPassesThroughWithoutCancelling() async throws {
        guard CGPreflightListenEventAccess(), CGPreflightPostEventAccess() else {
            throw XCTSkip("Global keyboard test requires Input Monitoring and Accessibility permissions.")
        }

        let cancelled = expectation(description: "Escape does not cancel")
        cancelled.isInverted = true
        let monitor = HotkeyMonitor(
            dictationShortcut: .rightCommand,
            ambientToggleShortcut: .ambientToggleDefault,
            correctionShortcut: .correctionDefault,
            onDictationDown: {},
            onDictationUp: {},
            onAmbientToggle: {},
            onCorrection: {},
            onCancel: { cancelled.fulfill() },
            recordingIsActive: { false }
        )
        try monitor.start()
        defer { monitor.stop() }

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true))
        let keyUp = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false))
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        await fulfillment(of: [cancelled], timeout: 0.3)
    }

    func testCommandEscapeInvokesCancel() async throws {
        guard CGPreflightListenEventAccess(), CGPreflightPostEventAccess() else {
            throw XCTSkip("Global keyboard test requires Input Monitoring and Accessibility permissions.")
        }

        let cancelled = expectation(description: "Command-Escape cancels recording")
        let monitor = HotkeyMonitor(
            dictationShortcut: .rightCommand,
            ambientToggleShortcut: .ambientToggleDefault,
            correctionShortcut: .correctionDefault,
            onDictationDown: {},
            onDictationUp: {},
            onAmbientToggle: {},
            onCorrection: {},
            onCancel: { cancelled.fulfill() },
            recordingIsActive: { true }
        )
        try monitor.start()
        defer { monitor.stop() }

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: true))
        let keyUp = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false))
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        await fulfillment(of: [cancelled], timeout: 1)
    }
}
