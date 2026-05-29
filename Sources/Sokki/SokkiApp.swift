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
                retryLastInsert: { appModel.retryLastInsert() },
                copyLastTranscript: { appModel.copyLastTranscript() },
                refreshPermissions: { appModel.refreshPermissions() },
                quit: { NSApplication.shared.terminate(nil) }
            )
        }
        .defaultSize(width: 680, height: 820)
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
