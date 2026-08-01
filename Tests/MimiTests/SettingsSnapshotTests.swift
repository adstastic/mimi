import AppKit
import SwiftUI
import XCTest
@testable import Mimi

@MainActor
final class SettingsSnapshotTests: XCTestCase {
    func testRenderSettingsSnapshot() throws {
        var config = MimiConfig.defaults
        config.ambientModeEnabled = true
        config.dictationPasteSettings.prePasteKeystroke = .returnKey
        config.ambientPasteSettings.prePasteKeystroke = .returnKey

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
        let size = try render(view, to: "/tmp/mimi-settings-snapshot.png")
        XCTAssertEqual(size.width, 430, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 1_000)
        XCTAssertLessThanOrEqual(size.height, 1_200)
        print("SETTINGS_SNAPSHOT_SIZE=\(Int(size.width))x\(Int(size.height))")
    }

    func testRenderEmptyVocabularySnapshot() throws {
        let size = try render(
            VocabularySettingsView(entries: .constant([])),
            to: "/tmp/mimi-vocabulary-empty-snapshot.png"
        )
        XCTAssertEqual(size.width, 540, accuracy: 0.5)
        XCTAssertEqual(size.height, 420, accuracy: 0.5)
    }

    func testRenderInvalidVocabularySnapshot() throws {
        let entries = [
            VocabularyEntry(writtenForm: "Wispr Flow", spokenAliases: ["shared alias"]),
            VocabularyEntry(writtenForm: "PyTorch", spokenAliases: ["shared alias"])
        ]
        let size = try render(
            VocabularySettingsView(entries: .constant(entries)),
            to: "/tmp/mimi-vocabulary-invalid-snapshot.png"
        )
        XCTAssertEqual(size.width, 540, accuracy: 0.5)
        XCTAssertEqual(size.height, 420, accuracy: 0.5)
    }

    func testRenderVocabularySnapshot() throws {
        let entries = [
            VocabularyEntry(writtenForm: "Wispr Flow", spokenAliases: ["whisper flow"]),
            VocabularyEntry(writtenForm: "PyTorch", spokenAliases: ["pie torch", "pie talk"]),
            VocabularyEntry(writtenForm: "Kubernetes", spokenAliases: ["kube er net ease"], isEnabled: false)
        ]

        let size = try render(
            VocabularySettingsView(entries: .constant(entries)),
            to: "/tmp/mimi-vocabulary-snapshot.png"
        )
        XCTAssertEqual(size.width, 540, accuracy: 0.5)
        XCTAssertEqual(size.height, 420, accuracy: 0.5)
        print("VOCABULARY_SNAPSHOT_SIZE=\(Int(size.width))x\(Int(size.height))")
    }

    private func render<Content: View>(_ view: Content, to path: String) throws -> CGSize {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        guard ProcessInfo.processInfo.environment["MIMI_WRITE_SETTINGS_SNAPSHOT"] == "1" else { return size }

        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: representation)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
        return size
    }
}
