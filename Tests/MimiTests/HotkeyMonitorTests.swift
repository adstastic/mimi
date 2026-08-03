import CoreGraphics
import XCTest
@testable import Mimi

@MainActor
final class HotkeyMonitorTests: XCTestCase {
    func testCommandEscapeInvokesCancel() async throws {
        guard CGPreflightListenEventAccess(), CGPreflightPostEventAccess() else {
            throw XCTSkip("Global keyboard test requires Input Monitoring and Accessibility permissions.")
        }

        let cancelled = expectation(description: "Command-Escape cancels recording")
        let monitor = HotkeyMonitor(
            dictationShortcut: .rightCommand,
            ambientToggleShortcut: .ambientToggleDefault,
            onDictationDown: {},
            onDictationUp: {},
            onAmbientToggle: {},
            onCancel: { cancelled.fulfill() }
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
