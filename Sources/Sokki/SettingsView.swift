import SwiftUI

struct SettingsView: View {
    let config: SokkiConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sokki Settings")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                SettingsRow(title: "Preferred backend", value: config.preferredBackend.displayName)
                SettingsRow(title: "Silence threshold", value: "\(Int(config.silenceThresholdDBFS)) dBFS")
                SettingsRow(title: "Silence duration", value: "\(config.silenceDurationMilliseconds) ms")
                SettingsRow(title: "Pre-roll", value: "\(config.preRollMilliseconds) ms")
                SettingsRow(title: "Ambient mode", value: config.ambientModeEnabled ? "On" : "Off")
                SettingsRow(title: "Telemetry", value: config.telemetryEnabled ? "On" : "Off")
                SettingsRow(title: "Runtime network", value: config.allowsNetworkAccess ? "On" : "Off")
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 260, alignment: .topLeading)
    }
}

private struct SettingsRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
        }
    }
}
