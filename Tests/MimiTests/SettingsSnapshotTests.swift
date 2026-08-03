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
            lastDictation: TranscriptEntry(
                sourceText: "This is a representative recent transcript long enough to wrap across several lines in the settings window and expose its maximum practical height.",
                text: "This is a representative recent transcript long enough to wrap across several lines in the settings window and expose its maximum practical height.",
                backend: .appleSpeechTranscriber,
                audioURL: nil,
                createdAt: Date(timeIntervalSince1970: 0)
            ),
            liveTranscript: "This is a representative live transcript long enough to wrap across several lines while recording remains active.",
            enrollVoiceprint: {},
            verifyVoiceprint: {},
            resetVoiceprint: {},
            copyLastTranscript: {},
            requestLastTranscriptCorrection: {},
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

    func testRenderLastDictationCorrectionSnapshot() throws {
        let entry = TranscriptEntry(
            sourceText: "We use pie torch and whisper flow.",
            text: "We use pie torch and whisper flow.",
            backend: .appleSpeechTranscriber,
            audioURL: URL(fileURLWithPath: "/tmp/latest.wav"),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let size = try render(
            LastDictationCorrectionView(
                entry: entry,
                initialCorrectedText: "We use PyTorch and Wispr Flow.",
                save: { _, _, _ in .success(()) }
            ),
            to: "/tmp/mimi-last-dictation-correction-snapshot.png"
        )
        XCTAssertEqual(size.width, 560, accuracy: 0.5)
        XCTAssertEqual(size.height, 420, accuracy: 0.5)
        print("LAST_DICTATION_CORRECTION_SNAPSHOT_SIZE=\(Int(size.width))x\(Int(size.height))")
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
