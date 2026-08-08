import AppKit
import SwiftUI
import XCTest
@testable import Mimi

@MainActor
final class SettingsSnapshotTests: XCTestCase {
    func testRenderSettingsSnapshots() throws {
        var config = MimiConfig.defaults
        config.ambientModeEnabled = true
        config.dictationPasteSettings.prePasteKeystroke = .returnKey
        config.ambientPasteSettings.prePasteKeystroke = .returnKey

        let defaults = UserDefaults.standard
        let previousPane = defaults.string(forKey: SettingsPane.selectionDefaultsKey)
        defer {
            if let previousPane {
                defaults.set(previousPane, forKey: SettingsPane.selectionDefaultsKey)
            } else {
                defaults.removeObject(forKey: SettingsPane.selectionDefaultsKey)
            }
        }

        for pane in SettingsPane.allCases {
            defaults.set(pane.rawValue, forKey: SettingsPane.selectionDefaultsKey)
            let path = pane == .general
                ? "/tmp/mimi-settings-snapshot.png"
                : "/tmp/mimi-settings-\(pane.rawValue)-snapshot.png"
            let size = try render(makeSettingsView(config: config), to: path)

            XCTAssertEqual(size.width, 500, accuracy: 0.5, "\(pane.rawValue) pane width changed")
            XCTAssertEqual(size.height, 500, accuracy: 0.5, "\(pane.rawValue) pane height changed")
            print("SETTINGS_\(pane.rawValue.uppercased())_SNAPSHOT_SIZE=\(Int(size.width))x\(Int(size.height))")
        }
    }

    private func makeSettingsView(config: MimiConfig) -> SettingsView {
        SettingsView(
            config: .constant(config),
            permissionStatus: PermissionStatus(microphone: true, accessibility: true, inputMonitoring: true),
            inputDevices: [AudioInputDevice(id: "studio-mic", name: "Studio Microphone")],
            voiceprintStatus: "Enrolled — 256D threshold 0.78",
            voiceprintProfileExists: true,
            voiceprintBusy: false,
            configErrorText: nil,
            enrollVoiceprint: {},
            verifyVoiceprint: {},
            resetVoiceprint: {},
            shortcutRecordingChanged: { _ in },
            refreshPermissions: {},
            refreshInputDevices: {},
            openConfigFile: {},
            reloadConfig: {}
        )
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
