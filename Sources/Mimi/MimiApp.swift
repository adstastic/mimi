import AppKit
import Darwin
import SwiftUI

@main
struct MimiApp: App {
    private static let instanceGuard = SingleInstanceGuard()

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
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
                lastDictation: appModel.lastDictation,
                liveTranscript: appModel.liveTranscript,
                correctionRequestID: appModel.correctionRequestID,
                consumeCorrectionRequest: { appModel.consumeCorrectionRequest($0) },
                enrollVoiceprint: { appModel.enrollVoiceprint() },
                verifyVoiceprint: { appModel.verifyVoiceprint() },
                resetVoiceprint: { appModel.resetVoiceprint() },
                copyLastTranscript: { appModel.copyLastTranscript() },
                correctLastTranscript: {
                    appModel.correctLastTranscript(id: $0, text: $1, corrections: $2)
                },
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
                    appModel.quit()
                }
                .keyboardShortcut("q")
            }
        }
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        Group {
            if let image = AppBrand.menuBarImage {
                Image(nsImage: image)
                    .accessibilityLabel(AppBrand.name)
            } else {
                Image(systemName: "ear")
                    .accessibilityLabel(AppBrand.name)
            }
        }
        .onChange(of: appModel.correctionRequestID) { _, newValue in
            guard newValue > 0 else { return }
            openSettings()
        }
    }
}

private struct MimiMenu: View {
    @ObservedObject var appModel: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(appModel.statusText)
            .disabled(true)
        if let configErrorText = appModel.configErrorText {
            Text(configErrorText)
                .disabled(true)
        }

        Toggle("Ambient Mode", isOn: $appModel.config.ambientModeEnabled)

        Divider()

        Button("Correct Last Dictation…") {
            appModel.requestLastTranscriptCorrection()
            openSettings()
        }
        .disabled(appModel.lastDictation == nil)

        Button("Settings…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Open Config File") {
            appModel.openConfigFile()
        }

        Button("Reload Config") {
            appModel.reloadConfig()
        }

        Divider()

        Button("Quit \(AppBrand.name)") {
            appModel.quit()
        }
        .keyboardShortcut("q")
    }
}
