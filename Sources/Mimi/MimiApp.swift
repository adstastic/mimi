import AppKit
import Combine
import SwiftUI

@main
struct MimiApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appModel = AppModel()
    private let permissionRefreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

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
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    appModel.refreshPermissions()
                }
            }
            .onReceive(permissionRefreshTimer) { _ in
                appModel.refreshPermissions()
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
