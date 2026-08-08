import AppKit
import Darwin
import SwiftUI

@main
struct MimiApp: App {
    static let correctionWindowID = "last-dictation-correction"
    private static let instanceGuard = SingleInstanceGuard()

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
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

        Window("Correct Last Dictation", id: Self.correctionWindowID) {
            CorrectionWindow(appModel: appModel)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)

        Settings {
            SettingsView(
                config: $appModel.config,
                permissionStatus: appModel.permissionStatus,
                inputDevices: appModel.inputDevices,
                voiceprintStatus: appModel.voiceprintStatus,
                voiceprintProfileExists: appModel.voiceprintProfileExists,
                voiceprintBusy: appModel.voiceprintBusy,
                configErrorText: appModel.configErrorText,
                enrollVoiceprint: { appModel.enrollVoiceprint() },
                verifyVoiceprint: { appModel.verifyVoiceprint() },
                resetVoiceprint: { appModel.resetVoiceprint() },
                shortcutRecordingChanged: { appModel.setShortcutRecording($0) },
                refreshPermissions: { appModel.refreshPermissions() },
                refreshInputDevices: { appModel.refreshInputDevices() },
                openConfigFile: { appModel.openConfigFile() },
                reloadConfig: { appModel.reloadConfig() }
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
            openWindow(id: Self.correctionWindowID)
        }
    }
}

private struct CorrectionWindow: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        Group {
            if let entry = appModel.lastDictation {
                LastDictationCorrectionView(
                    entry: entry,
                    save: { appModel.correctLastTranscript(id: $0, text: $1, corrections: $2) }
                )
                .id(entry.id)
            }
        }
        .task(id: appModel.correctionRequestID) {
            guard appModel.correctionRequestID > 0 else { return }
            appModel.consumeCorrectionRequest(appModel.correctionRequestID)
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

        Button("Copy Last Dictation") {
            appModel.copyLastTranscript()
        }
        .disabled(appModel.lastDictation == nil)

        Button("Correct Last Dictation…") {
            appModel.requestLastTranscriptCorrection()
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
