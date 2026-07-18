import AppKit
import Darwin
import SwiftUI

@main
struct MimiApp: App {
    private static let instanceGuard = SingleInstanceGuard()

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appModel: AppModel

    init() {
        if !Self.instanceGuard.isPrimary {
            Self.instanceGuard.activateExistingInstance()
            Darwin.exit(0)
        }
        _appModel = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup(AppBrand.name) {
            SettingsView(
                config: $appModel.config,
                statusText: appModel.statusText,
                permissionStatus: appModel.permissionStatus,
                inputDevices: appModel.inputDevices,
                voiceprintStatus: appModel.voiceprintStatus,
                voiceprintProfileExists: appModel.voiceprintProfileExists,
                voiceprintBusy: appModel.voiceprintBusy,
                lastTranscript: appModel.lastTranscript,
                liveTranscript: appModel.liveTranscript,
                enrollVoiceprint: { appModel.enrollVoiceprint() },
                verifyVoiceprint: { appModel.verifyVoiceprint() },
                resetVoiceprint: { appModel.resetVoiceprint() },
                copyLastTranscript: { appModel.copyLastTranscript() },
                shortcutRecordingChanged: { appModel.setShortcutRecording($0) },
                refreshPermissions: { appModel.refreshPermissions() },
                refreshInputDevices: { appModel.refreshInputDevices() }
            )
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    appModel.refreshPermissions()
                }
            }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit \(AppBrand.name)") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}
