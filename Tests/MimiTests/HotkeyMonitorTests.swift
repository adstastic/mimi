import CoreGraphics
import XCTest
@testable import Mimi

@MainActor
final class HotkeyMonitorTests: XCTestCase {
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
            onCancel: { cancelled.fulfill() }
        )
        try monitor.start()
        defer { monitor.stop() }
        XCTAssertTrue(monitor.usesActiveEventTap)

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
