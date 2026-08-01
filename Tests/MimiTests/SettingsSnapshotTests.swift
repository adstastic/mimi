import AppKit
import SwiftUI
import XCTest
@testable import Mimi

@MainActor
final class SettingsSnapshotTests: XCTestCase {
    func testRenderSettingsSnapshot() throws {
        var config = MimiConfig.defaults
        config.ambientModeEnabled = true
        config.ambientPrePasteKeystroke = .returnKey
        config.ambientPostPasteKeystroke = .returnKey

        let view = SettingsView(
            config: .constant(config),
            statusText: "Ready — hold Right Command to dictate",
            permissionStatus: PermissionStatus(microphone: true, accessibility: true, inputMonitoring: true),
            inputDevices: [AudioInputDevice(id: "studio-mic", name: "Studio Microphone")],
            voiceprintStatus: "Enrolled — 256D threshold 0.78",
            voiceprintProfileExists: true,
            voiceprintBusy: false,
            lastTranscript: "This is a representative recent transcript long enough to wrap across several lines in the settings window and expose its maximum practical height.",
            liveTranscript: "This is a representative live transcript long enough to wrap across several lines while recording remains active.",
            enrollVoiceprint: {},
            verifyVoiceprint: {},
            resetVoiceprint: {},
            copyLastTranscript: {},
            shortcutRecordingChanged: { _ in },
            refreshPermissions: {},
            refreshInputDevices: {}
        )
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        XCTAssertEqual(size.width, 430, accuracy: 0.5)
        XCTAssertEqual(size.height, 900, accuracy: 0.5)
        print("SETTINGS_SNAPSHOT_SIZE=\(Int(size.width))x\(Int(size.height))")

        guard ProcessInfo.processInfo.environment["MIMI_WRITE_SETTINGS_SNAPSHOT"] == "1" else { return }
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let representation = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("Could not create bitmap representation")
            return
        }
        host.cacheDisplay(in: host.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            XCTFail("Could not encode snapshot")
            return
        }
        try data.write(to: URL(fileURLWithPath: "/tmp/mimi-settings-snapshot.png"))
    }
}
