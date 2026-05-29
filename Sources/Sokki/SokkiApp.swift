import AppKit
import SwiftUI

@main
struct SokkiApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("Sokki") {
            SettingsView(
                config: $appModel.config,
                statusText: appModel.statusText,
                hotkeyStatus: appModel.hotkeyStatus,
                permissionStatus: appModel.permissionStatus,
                modelLoading: appModel.modelLoading,
                modelReady: appModel.modelReady,
                lastTranscript: appModel.lastTranscript,
                liveTranscript: appModel.liveTranscript,
                copyLastTranscript: { appModel.copyLastTranscript() },
                shortcutRecordingChanged: { appModel.setShortcutRecording($0) },
                refreshPermissions: { appModel.refreshPermissions() },
                quit: { NSApplication.shared.terminate(nil) }
            )
        }
        .defaultSize(width: 760, height: 900)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Sokki") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}
