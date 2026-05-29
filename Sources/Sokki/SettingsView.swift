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
    let copyLastTranscript: () -> Void
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
                SettingsRow(title: "Hotkey", value: hotkeyStatus)
                SettingsRow(title: "Gesture", value: "Right Command: hold or tap")
                SettingsRow(title: "Backend", value: config.preferredBackend.displayName)
                SettingsRow(title: "Pre-roll", value: "\(config.preRollMilliseconds) ms")
                Toggle("End recording on silence", isOn: $config.silenceAutoStopEnabled)
                Toggle("Press Enter after pasting", isOn: $config.pressEnterAfterPaste)
                SettingsRow(title: "Ambient mode", value: config.ambientModeEnabled ? "On" : "Off")
                SettingsRow(title: "Telemetry", value: config.telemetryEnabled ? "On" : "Off")
                SettingsRow(title: "Cloud ASR", value: config.cloudTranscriptionEnabled ? "On" : "Off")
                SettingsRow(title: "Model download", value: config.modelDownloadEnabled ? "On first run" : "Off")
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
                    Text(modelReady ? "Loaded" : (modelLoading ? "Loading MLX Parakeet v2…" : "Not loaded"))
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
