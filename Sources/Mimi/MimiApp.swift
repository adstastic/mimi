import AppKit
import SwiftUI

@main
struct MimiApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup(AppBrand.name) {
            SettingsView(
                config: $appModel.config,
                statusText: appModel.statusText,
                hotkeyStatus: appModel.hotkeyStatus,
                permissionStatus: appModel.permissionStatus,
                modelLoading: appModel.modelLoading,
                modelReady: appModel.modelReady,
                inputDevices: appModel.inputDevices,
                lastTranscript: appModel.lastTranscript,
                liveTranscript: appModel.liveTranscript,
                copyLastTranscript: { appModel.copyLastTranscript() },
                shortcutRecordingChanged: { appModel.setShortcutRecording($0) },
                refreshPermissions: { appModel.refreshPermissions() },
                refreshInputDevices: { appModel.refreshInputDevices() },
                quit: { NSApplication.shared.terminate(nil) }
            )
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
