import AppKit
import SwiftUI

struct SettingsView: View {
    @Binding var config: MimiConfig
    let statusText: String
    let permissionStatus: PermissionStatus
    let inputDevices: [AudioInputDevice]
    let lastTranscript: String?
    let liveTranscript: String?
    let copyLastTranscript: () -> Void
    let shortcutRecordingChanged: (Bool) -> Void
    let refreshPermissions: () -> Void
    let refreshInputDevices: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            SettingsCard("Dictation", systemImage: "waveform") {
                    PickerLine("Model", systemImage: "cpu") {
                        Picker("Model", selection: $config.preferredBackend) {
                            ForEach(ASRBackend.allCases, id: \.self) { backend in
                                Text(backend.displayName).tag(backend)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                    }

                    InputDevicePickerLine(
                        selectedID: $config.inputDeviceID,
                        devices: inputDevices,
                        refresh: refreshInputDevices
                    )

                    ToggleLine("End shortcut on silence", systemImage: "speaker.slash", isOn: $config.silenceAutoStopEnabled)
                    ToggleLine("Shortcut presses Return", systemImage: "return", isOn: $config.pressEnterAfterPaste)
                }

                SettingsCard("Ambient", systemImage: "ear.and.waveform") {
                    ToggleLine(
                        "Ambient mode",
                        systemImage: "ear.and.waveform",
                        isOn: $config.ambientModeEnabled,
                        disabled: !backendCapabilities.supportsAmbient
                    )
                    ToggleLine(
                        "Press Return on start",
                        systemImage: "return",
                        isOn: $config.ambientPressEnterOnStart,
                        disabled: !backendCapabilities.supportsAmbient
                    )
                    Label(
                        backendCapabilities.supportsAmbient
                            ? "Ambient always stops on pause and presses Return."
                            : "Ambient requires Apple SpeechTranscriber.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                SettingsCard("Shortcuts", systemImage: "keyboard") {
                    ShortcutRecorderRow(
                        title: "Dictation",
                        systemImage: "mic",
                        shortcut: $config.dictationShortcut,
                        onRecordingChanged: shortcutRecordingChanged
                    )
                    ShortcutRecorderRow(
                        title: "Ambient",
                        systemImage: "switch.2",
                        shortcut: $config.ambientToggleShortcut,
                        disabled: !backendCapabilities.supportsAmbient,
                        onRecordingChanged: shortcutRecordingChanged
                    )
                    if config.dictationShortcut == config.ambientToggleShortcut {
                        Label("Ambient shortcut ignored because it matches dictation.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                SettingsCard("Silence", systemImage: "waveform.badge.magnifyingglass") {
                    PickerLine(
                        "Stop detection",
                        systemImage: "waveform.and.magnifyingglass"
                    ) {
                        Picker("Stop detection", selection: $config.silenceDetectionMode) {
                            ForEach(SilenceDetectionMode.allCases, id: \.self) { mode in
                                Text(mode.displayName)
                                    .tag(mode)
                                    .disabled(!backendCapabilities.supportsSilenceDetectionMode(mode))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                    }

                    SliderLine(
                        "Noise floor",
                        value: "\(Int(config.silenceThresholdDBFS)) dBFS",
                        systemImage: "dial.low"
                    ) {
                        Slider(value: $config.silenceThresholdDBFS, in: -65 ... -15, step: 1)
                            .frame(width: 170)
                    }
                    SliderLine(
                        "Stop after",
                        value: String(format: "%.1f s", Double(config.silenceDurationMilliseconds) / 1_000.0),
                        systemImage: "timer"
                    ) {
                        Slider(
                            value: Binding(
                                get: { Double(config.silenceDurationMilliseconds) / 1_000.0 },
                                set: { config.silenceDurationMilliseconds = Int(($0 * 1_000).rounded()) }
                            ),
                            in: 0.0 ... 3.0,
                            step: 0.1
                        )
                        .frame(width: 170)
                    }
                }

                SettingsCard(
                    "Permissions",
                    systemImage: "lock.shield",
                    trailing: AnyView(
                        Button {
                            refreshPermissions()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh permissions")
                        .controlSize(.small)
                    )
                ) {
                    PermissionLine("Microphone", systemImage: "mic", granted: permissionStatus.microphone) {
                        openPrivacyPane("Privacy_Microphone")
                    }
                    PermissionLine("Accessibility", systemImage: "accessibility", granted: permissionStatus.accessibility) {
                        openPrivacyPane("Privacy_Accessibility")
                    }
                    PermissionLine("Input Monitoring", systemImage: "keyboard.badge.eye", granted: permissionStatus.inputMonitoring) {
                        openPrivacyPane("Privacy_ListenEvent")
                    }
                }

            if let liveTranscript, !liveTranscript.isEmpty {
                TranscriptCard(title: "Live", systemImage: "text.bubble", text: liveTranscript)
            }

            if let lastTranscript {
                TranscriptCard(title: "Last", systemImage: "doc.on.clipboard", text: lastTranscript) {
                    copyLastTranscript()
                }
            }
        }
        .padding(10)
        .frame(width: 430, alignment: .topLeading)
        .fixedSize(horizontal: true, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var backendCapabilities: ASRBackendCapabilities {
        config.preferredBackend.capabilities
    }

    private var header: some View {
        HStack(spacing: 8) {
            AppLogoView()

            Text(AppBrand.name)
                .font(.title.bold())

            StatusDot(color: statusColor, title: statusText)

            Spacer()
        }
    }

    private var statusColor: Color {
        let lowercased = statusText.lowercased()
        if lowercased.contains("error") || lowercased.contains("missing") || lowercased.contains("denied") {
            return .red
        }
        if lowercased.contains("preparing") || lowercased.contains("loading") || lowercased.contains("starting") || lowercased.contains("transcribing") || lowercased.contains("recording") {
            return .yellow
        }
        return .green
    }

    private func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct AppLogoView: View {
    var body: some View {
        Group {
            if let image = AppBrand.logoImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "ear")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor))
            }
        }
        .frame(width: 34, height: 34)
    }
}

private struct StatusDot: View {
    let color: Color
    let title: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color.primary.opacity(0.18), lineWidth: 1))
            .help(title)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    // TODO(ponytail): replace AnyView with a generic trailing view if more cards need actions.
    let trailing: AnyView?
    let content: Content

    init(_ title: String, systemImage: String, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
                trailing
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

private struct ToggleLine: View {
    let title: String
    let systemImage: String
    let disabled: Bool
    @Binding var isOn: Bool

    init(_ title: String, systemImage: String, isOn: Binding<Bool>, disabled: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.disabled = disabled
        _isOn = isOn
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .disabled(disabled)
        }
        .opacity(disabled ? 0.45 : 1)
    }
}

private struct PickerLine<PickerContent: View>: View {
    let title: String
    let systemImage: String
    let picker: PickerContent

    init(_ title: String, systemImage: String, @ViewBuilder picker: () -> PickerContent) {
        self.title = title
        self.systemImage = systemImage
        self.picker = picker()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
            Spacer()
            picker
        }
    }
}

private struct InputDevicePickerLine: View {
    @Binding var selectedID: String?
    let devices: [AudioInputDevice]
    let refresh: () -> Void

    private var selection: Binding<String> {
        Binding(
            get: { selectedID ?? "" },
            set: { selectedID = $0.isEmpty ? nil : $0 }
        )
    }

    private var selectedDeviceMissing: Bool {
        guard let selectedID else { return false }
        return !devices.contains { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text("Input")
                Spacer()
                Picker("Input", selection: selection) {
                    Text("System Default").tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh input devices")
                .controlSize(.small)
            }
            if selectedDeviceMissing {
                Label("Selected microphone is not connected.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct SliderLine<SliderContent: View>: View {
    let title: String
    let value: String
    let systemImage: String
    let slider: SliderContent

    init(_ title: String, value: String, systemImage: String, @ViewBuilder slider: () -> SliderContent) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.slider = slider()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            slider
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }
}

private struct ShortcutRecorderRow: View {
    let title: String
    let systemImage: String
    @Binding var shortcut: MimiShortcut
    let disabled: Bool
    let onRecordingChanged: (Bool) -> Void

    init(
        title: String,
        systemImage: String,
        shortcut: Binding<MimiShortcut>,
        disabled: Bool = false,
        onRecordingChanged: @escaping (Bool) -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        _shortcut = shortcut
        self.disabled = disabled
        self.onRecordingChanged = onRecordingChanged
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
            Spacer()
            Text(shortcut.displayName)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            ShortcutRecorderButton(shortcut: $shortcut, disabled: disabled, onRecordingChanged: onRecordingChanged)
        }
        .opacity(disabled ? 0.45 : 1)
    }
}

private struct ShortcutRecorderButton: View {
    @Binding var shortcut: MimiShortcut
    let disabled: Bool
    let onRecordingChanged: (Bool) -> Void
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        Button {
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
        } label: {
            if recorder.isRecording {
                Label("Press…", systemImage: "record.circle")
            } else {
                Image(systemName: "pencil")
            }
        }
        .controlSize(.small)
        .disabled(disabled)
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
    private var pendingModifierShortcut: MimiShortcut?
    private var sawKeyDown = false

    func start(onCapture: @escaping (MimiShortcut) -> Void, onFinish: @escaping () -> Void) {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                if event.keyCode == 53 {
                    self.stop()
                    onFinish()
                    return nil
                }
                self.sawKeyDown = true
                guard let shortcut = MimiShortcut.from(event: event) else { return event }
                onCapture(shortcut)
                self.stop()
                onFinish()
                return nil
            case .flagsChanged:
                guard let flag = MimiShortcut.modifierFlag(forKeyCode: Int(event.keyCode)) else { return event }
                if event.modifierFlags.contains(flag) {
                    self.pendingModifierShortcut = MimiShortcut(keyCode: Int(event.keyCode), modifierFlagsRaw: flag.rawValue)
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

private struct PermissionLine: View {
    let title: String
    let systemImage: String
    let granted: Bool
    let open: () -> Void

    init(_ title: String, systemImage: String, granted: Bool, open: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.granted = granted
        self.open = open
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
            Spacer()
            StatusDot(color: granted ? .green : .orange, title: granted ? "Granted" : "Missing")
            Button {
                open()
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .help("Open \(title) settings")
            .controlSize(.small)
        }
    }
}

private struct TranscriptCard: View {
    let title: String
    let systemImage: String
    let text: String
    let action: (() -> Void)?

    init(title: String, systemImage: String, text: String, action: (() -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.text = text
        self.action = action
    }

    var body: some View {
        SettingsCard(title, systemImage: systemImage) {
            HStack(alignment: .top) {
                Text(text)
                    .lineLimit(4)
                    .textSelection(.enabled)
                Spacer()
                if let action {
                    Button("Copy", action: action)
                        .controlSize(.small)
                }
            }
        }
    }
}
