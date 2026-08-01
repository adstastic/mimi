import AppKit
import Darwin
import SwiftUI

// PROTOTYPE: Does menu-bar-only launch with on-demand Settings feel right for Mimi?
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
        MenuBarExtra {
            MimiMenu(appModel: appModel)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.menu)

        Settings {
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

    @ViewBuilder
    private var menuBarLabel: some View {
        if let image = AppBrand.menuBarImage {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 18)
                .accessibilityLabel(AppBrand.name)
        } else {
            Image(systemName: "ear")
                .accessibilityLabel(AppBrand.name)
        }
    }
}

private struct MimiMenu: View {
    @ObservedObject var appModel: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(appModel.statusText)
            .disabled(true)

        Toggle("Ambient Mode", isOn: $appModel.config.ambientModeEnabled)

        Divider()

        Button("Settings…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit \(AppBrand.name)") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
