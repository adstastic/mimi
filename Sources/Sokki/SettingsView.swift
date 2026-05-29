import AppKit
import SwiftUI

struct SettingsView: View {
    @Binding var config: SokkiConfig
    let statusText: String
    let hotkeyStatus: String
    let permissionStatus: PermissionStatus
    let modelLoading: Bool
    let modelReady: Bool
    let lastTranscript: String?
    let liveTranscript: String?
    let copyLastTranscript: () -> Void
    let shortcutRecordingChanged: (Bool) -> Void
    let refreshPermissions: () -> Void
    let quit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sokki")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Quit", action: quit)
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsRow(title: "Status", value: statusText)
                SettingsRow(title: "Hotkeys", value: hotkeyStatus)
                SettingsRow(title: "Gesture", value: "Hold or tap dictation shortcut")
                Picker("Backend", selection: $config.preferredBackend) {
                    ForEach(ASRBackend.allCases, id: \.self) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                SettingsRow(title: "Pre-roll", value: "\(config.preRollMilliseconds) ms")
                Toggle("End recording on silence", isOn: $config.silenceAutoStopEnabled)
                Toggle("Press Enter after pasting", isOn: $config.pressEnterAfterPaste)
                Toggle("Ambient mode", isOn: $config.ambientModeEnabled)
                Text("Ambient mode keeps the mic on and starts dictation with Apple voice activity detection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingsRow(title: "Model download", value: config.modelDownloadEnabled ? "On first run" : "Off")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Shortcuts")
                    .foregroundStyle(.secondary)
                ShortcutRecorderRow(
                    title: "Dictation",
                    help: "Hold to record, tap to toggle recording.",
                    shortcut: $config.dictationShortcut,
                    onRecordingChanged: shortcutRecordingChanged
                )
                ShortcutRecorderRow(
                    title: "Ambient toggle",
                    help: "Turn ambient mode on or off system-wide.",
                    shortcut: $config.ambientToggleShortcut,
                    onRecordingChanged: shortcutRecordingChanged
                )
                if config.dictationShortcut == config.ambientToggleShortcut {
                    Text("Shortcuts match. Ambient toggle is ignored when it matches dictation.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Silence auto-stop")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Threshold")
                        Spacer()
                        Text("\(Int(config.silenceThresholdDBFS)) dBFS")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.silenceThresholdDBFS, in: -65 ... -15, step: 1)
                    Text("More negative = less sensitive. Less negative = ignores quieter/background sound.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Stop after silence")
                        Spacer()
                        Text(String(format: "%.1f s", Double(config.silenceDurationMilliseconds) / 1_000.0))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(config.silenceDurationMilliseconds) / 1_000.0 },
                            set: { config.silenceDurationMilliseconds = Int(($0 * 1_000).rounded()) }
                        ),
                        in: 0.3 ... 3.0,
                        step: 0.1
                    )
                    Text("Shorter = faster paste. Longer = fewer premature stops.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    StatusLight(ok: modelReady, warning: modelLoading)
                    Text(modelReady ? "Loaded" : (modelLoading ? "Loading…" : "Not loaded"))
                    if modelLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 80)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Permissions")
                        .foregroundStyle(.secondary)
                    Button("Refresh", action: refreshPermissions)
                        .controlSize(.small)
                }
                PermissionRow(title: "Microphone", granted: permissionStatus.microphone)
                PermissionRow(title: "Accessibility", granted: permissionStatus.accessibility)
                PermissionRow(title: "Input Monitoring", granted: permissionStatus.inputMonitoring)
                HStack {
                    Button("Open Accessibility") { openPrivacyPane("Privacy_Accessibility") }
                    Button("Open Input Monitoring") { openPrivacyPane("Privacy_ListenEvent") }
                    Button("Open Microphone") { openPrivacyPane("Privacy_Microphone") }
                }
            }

            if let liveTranscript, !liveTranscript.isEmpty {
                Divider()
                Text("Live transcript")
                    .foregroundStyle(.secondary)
                Text(liveTranscript)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            if let lastTranscript {
                Divider()
                HStack {
                    Text("Last transcript")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy", action: copyLastTranscript)
                }
                Text(lastTranscript)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: 760, height: 900, alignment: .topLeading)
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct ShortcutRecorderRow: View {
    let title: String
    let help: String
    @Binding var shortcut: SokkiShortcut
    let onRecordingChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .frame(width: 130, alignment: .leading)
                ShortcutRecorderButton(
                    shortcut: $shortcut,
                    onRecordingChanged: onRecordingChanged
                )
                Text(shortcut.displayName)
                    .foregroundStyle(.secondary)
            }
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 130)
        }
    }
}

private struct ShortcutRecorderButton: View {
    @Binding var shortcut: SokkiShortcut
    let onRecordingChanged: (Bool) -> Void
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        Button(recorder.isRecording ? "Press shortcut…" : "Change") {
            if recorder.isRecording {
                recorder.stop()
                onRecordingChanged(false)
            } else {
                onRecordingChanged(true)
                recorder.start(
                    onCapture: { shortcut in
                        self.shortcut = shortcut
                    },
                    onFinish: {
                        onRecordingChanged(false)
                    }
                )
            }
        }
        .onDisappear {
            if recorder.isRecording {
                recorder.stop()
                onRecordingChanged(false)
            }
        }
    }
}

@MainActor
private final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?
    private var pendingModifierShortcut: SokkiShortcut?
    private var sawKeyDown = false

    func start(onCapture: @escaping (SokkiShortcut) -> Void, onFinish: @escaping () -> Void) {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                if event.keyCode == 53 { // Escape cancels recording.
                    self.stop()
                    onFinish()
                    return nil
                }
                self.sawKeyDown = true
                guard let shortcut = SokkiShortcut.from(event: event) else { return event }
                onCapture(shortcut)
                self.stop()
                onFinish()
                return nil
            case .flagsChanged:
                guard let flag = SokkiShortcut.modifierFlag(forKeyCode: Int(event.keyCode)) else { return event }
                if event.modifierFlags.contains(flag) {
                    self.pendingModifierShortcut = SokkiShortcut(keyCode: Int(event.keyCode), modifierFlagsRaw: flag.rawValue)
                    return nil
                }
                if !self.sawKeyDown,
                   let shortcut = self.pendingModifierShortcut,
                   shortcut.keyCode == Int(event.keyCode) {
                    onCapture(shortcut)
                    self.stop()
                    onFinish()
                    return nil
                }
                return nil
            default:
                return event
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        pendingModifierShortcut = nil
        sawKeyDown = false
        isRecording = false
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusLight(ok: granted, warning: false)
            Text(title)
            Text(granted ? "Granted" : "Missing")
                .foregroundStyle(.secondary)
        }
    }
}

private struct StatusLight: View {
    let ok: Bool
    let warning: Bool

    var body: some View {
        Circle()
            .fill(ok ? Color.green : (warning ? Color.yellow : Color.red))
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
    }
}

private struct SettingsRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .lineLimit(2)
        }
    }
}
