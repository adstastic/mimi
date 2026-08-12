import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import MimiSpeech
import SwiftUI

private enum SettingsField: Hashable {
    case shortcutBeforePasteDelay
    case shortcutAfterPasteDelay
    case ambientBeforePasteDelay
    case ambientAfterPasteDelay
}

private enum PasteMode: Hashable {
    case shortcut
    case ambient
}

enum SettingsPane: String, CaseIterable {
    static let selectionDefaultsKey = "Mimi.Settings.selectedPane.v1"

    case general
    case paste
    case shortcuts
    case voice
    case advanced
}

struct SettingsView: View {
    @Binding var config: MimiConfig
    @AppStorage(SettingsPane.selectionDefaultsKey) private var selectedPane = SettingsPane.general

    let permissionStatus: PermissionStatus
    let inputDevices: [AudioInputDevice]
    let voiceprintStatus: String
    let voiceprintProfileExists: Bool
    let voiceprintBusy: Bool
    let configErrorText: String?
    let enrollVoiceprint: () -> Void
    let verifyVoiceprint: () -> Void
    let resetVoiceprint: () -> Void
    let shortcutRecordingChanged: (Bool) -> Void
    let refreshPermissions: () -> Void
    let refreshInputDevices: () -> Void
    let openConfigFile: () -> Void
    let reloadConfig: () -> Void

    var body: some View {
        TabView(selection: $selectedPane) {
            Tab("General", systemImage: "gear", value: .general) {
                GeneralSettingsPane(
                    config: $config,
                    permissionStatus: permissionStatus,
                    inputDevices: inputDevices,
                    refreshPermissions: refreshPermissions,
                    refreshInputDevices: refreshInputDevices
                )
            }

            Tab("Paste", systemImage: "doc.on.clipboard", value: .paste) {
                PasteSettingsPane(
                    config: $config,
                    shortcutRecordingChanged: shortcutRecordingChanged,
                    openConfigFile: openConfigFile
                )
            }

            Tab("Shortcuts", systemImage: "keyboard", value: .shortcuts) {
                ShortcutSettingsPane(
                    config: $config,
                    shortcutRecordingChanged: shortcutRecordingChanged
                )
            }

            Tab("My Voice", systemImage: "person.wave.2", value: .voice) {
                VoiceSettingsPane(
                    config: $config,
                    status: voiceprintStatus,
                    profileExists: voiceprintProfileExists,
                    busy: voiceprintBusy,
                    enroll: enrollVoiceprint,
                    verify: verifyVoiceprint,
                    reset: resetVoiceprint
                )
            }

            Tab("Advanced", systemImage: "slider.horizontal.3", value: .advanced) {
                AdvancedSettingsPane(
                    config: $config,
                    configErrorText: configErrorText,
                    openConfigFile: openConfigFile,
                    reloadConfig: reloadConfig
                )
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let configErrorText {
                ConfigErrorBanner(message: configErrorText, openConfigFile: openConfigFile)
            }
        }
        .scenePadding()
        .frame(width: 500, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ConfigErrorBanner: View {
    let message: String
    let openConfigFile: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Open Config…", action: openConfigFile)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

private struct GeneralSettingsPane: View {
    @Binding var config: MimiConfig
    let permissionStatus: PermissionStatus
    let inputDevices: [AudioInputDevice]
    let refreshPermissions: () -> Void
    let refreshInputDevices: () -> Void

    private var allPermissionsGranted: Bool {
        permissionStatus.microphone
            && permissionStatus.accessibility
            && permissionStatus.inputMonitoring
    }

    var body: some View {
        Form {
            Section {
                PickerLine("Model", systemImage: "cpu") {
                    Picker("Model", selection: $config.preferredBackend) {
                        ForEach(ASRBackend.allCases, id: \.self) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                InputDevicePickerLine(
                    selectedID: $config.inputDeviceID,
                    devices: inputDevices,
                    refresh: refreshInputDevices
                )

                ToggleLine(
                    "Ambient mode",
                    systemImage: "ear.and.waveform",
                    isOn: $config.ambientModeEnabled,
                    disabled: !config.preferredBackend.capabilities.supportsAmbient
                )
                ToggleLine(
                    "End shortcut on silence",
                    systemImage: "speaker.slash",
                    isOn: $config.silenceAutoStopEnabled
                )
                ToggleLine(
                    "Show live transcript",
                    systemImage: "text.bubble",
                    isOn: $config.showLiveTranscript
                )
                ToggleLine(
                    "Remove filler words",
                    systemImage: "text.badge.minus",
                    isOn: $config.fillerCleanupEnabled
                )
            } header: {
                Text("Dictation")
            } footer: {
                Text("Live transcripts can include nearby speakers. My Voice filtering is applied after recording stops.")
            }

            Section {
                if allPermissionsGranted {
                    HStack(spacing: 8) {
                        Label("All required permissions granted", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button(action: refreshPermissions) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh permissions")
                    }
                } else {
                    MissingPermissionRows(
                        status: permissionStatus,
                        refreshPermissions: refreshPermissions
                    )
                    HStack {
                        Spacer()
                        Button("Refresh", systemImage: "arrow.clockwise", action: refreshPermissions)
                    }
                }
            } header: {
                Text("Permissions")
            }
        }
        .formStyle(.grouped)
    }
}

private struct MissingPermissionRows: View {
    let status: PermissionStatus
    let refreshPermissions: () -> Void

    var body: some View {
        if !status.microphone {
            PermissionLine("Microphone", systemImage: "mic") {
                requestMicrophoneAccess()
            }
        }
        if !status.accessibility {
            PermissionLine("Accessibility", systemImage: "accessibility") {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
        }
        if !status.inputMonitoring {
            PermissionLine("Input Monitoring", systemImage: "keyboard.badge.eye") {
                if !CGRequestListenEventAccess() {
                    openPrivacyPane("Privacy_ListenEvent")
                }
                refreshPermissions()
            }
        }
    }

    private func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async(execute: refreshPermissions)
            }
        default:
            openPrivacyPane("Privacy_Microphone")
        }
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct PasteSettingsPane: View {
    @Binding var config: MimiConfig
    @State private var pasteMode = PasteMode.shortcut
    @FocusState private var focusedField: SettingsField?

    let shortcutRecordingChanged: (Bool) -> Void
    let openConfigFile: () -> Void

    private var activePresetIndex: Int? {
        guard let name = config.activePastePresetName else { return nil }
        return config.pastePresets.firstIndex { $0.name == name }
    }

    private var activePresetSelection: Binding<String> {
        Binding(
            get: { config.activePastePresetName ?? "" },
            set: { config.activePastePresetName = $0.isEmpty ? nil : $0 }
        )
    }

    private var selectedPasteSettings: Binding<PasteSettings> {
        if let index = activePresetIndex {
            return $config.pastePresets[index].paste
        }
        switch pasteMode {
        case .shortcut:
            return $config.dictationPasteSettings
        case .ambient:
            return $config.ambientPasteSettings
        }
    }

    private var selectedDelayFields: (before: SettingsField, after: SettingsField) {
        switch pasteMode {
        case .shortcut:
            (.shortcutBeforePasteDelay, .shortcutAfterPasteDelay)
        case .ambient:
            (.ambientBeforePasteDelay, .ambientAfterPasteDelay)
        }
    }

    var body: some View {
        Form {
            Section {
                PickerLine("Preset", systemImage: "square.stack.3d.up") {
                    Picker("Preset", selection: activePresetSelection) {
                        Text(PastePreset.manualName).tag("")
                        ForEach(config.pastePresets) { preset in
                            Text(preset.name).tag(preset.name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                if activePresetIndex == nil {
                    PickerLine("Applies to", systemImage: "arrow.triangle.branch") {
                        Picker("Applies to", selection: $pasteMode) {
                            Text("Shortcut").tag(PasteMode.shortcut)
                            Text("Ambient").tag(PasteMode.ambient)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 170)
                    }
                }

                PasteSettingsEditor(
                    settings: selectedPasteSettings,
                    beforeDelayField: selectedDelayFields.before,
                    afterDelayField: selectedDelayFields.after,
                    focusedField: $focusedField,
                    disabled: activePresetIndex == nil
                        && pasteMode == .ambient
                        && !config.preferredBackend.capabilities.supportsAmbient,
                    onRecordingChanged: shortcutRecordingChanged
                )
            } header: {
                Text("Paste Behavior")
            } footer: {
                if activePresetIndex == nil {
                    Text("Manual settings can differ between shortcut and ambient dictation.")
                } else {
                    Text("The selected preset overrides both shortcut and ambient paste behavior.")
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preset collection")
                        Text("Add, rename, remove, or reorder presets in the config file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Config…", action: openConfigFile)
                }
            }
        }
        .formStyle(.grouped)
        .contentShape(Rectangle())
        .onTapGesture { focusedField = nil }
    }
}

private struct ShortcutSettingsPane: View {
    @Binding var config: MimiConfig
    let shortcutRecordingChanged: (Bool) -> Void

    var body: some View {
        Form {
            Section {
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
                    disabled: !config.preferredBackend.capabilities.supportsAmbient,
                    onRecordingChanged: shortcutRecordingChanged
                )
                ShortcutRecorderRow(
                    title: "Correct last",
                    systemImage: "pencil.line",
                    shortcut: $config.correctionShortcut,
                    onRecordingChanged: shortcutRecordingChanged
                )
                ShortcutRecorderRow(
                    title: "Next paste preset",
                    systemImage: "square.stack.3d.up",
                    shortcut: $config.pastePresetShortcut,
                    onRecordingChanged: shortcutRecordingChanged
                )
            } header: {
                Text("Global Shortcuts")
            } footer: {
                Text("Select the pencil button, then press the desired key combination.")
            }

            ShortcutConflictWarnings(config: config)
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutConflictWarnings: View {
    let config: MimiConfig

    var body: some View {
        if config.dictationShortcut == config.ambientToggleShortcut {
            WarningLabel("Ambient shortcut is ignored because it matches dictation.")
        }
        if config.correctionShortcut == config.dictationShortcut
            || config.correctionShortcut == config.ambientToggleShortcut {
            WarningLabel("Correct Last is ignored because it matches another shortcut.")
        }
        if config.pastePresetShortcut == config.dictationShortcut
            || config.pastePresetShortcut == config.ambientToggleShortcut
            || config.pastePresetShortcut == config.correctionShortcut {
            WarningLabel("Next Paste Preset is ignored because it matches another shortcut.")
        }
    }
}

private struct WarningLabel: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
    }
}

private struct VoiceSettingsPane: View {
    @Binding var config: MimiConfig
    let status: String
    let profileExists: Bool
    let busy: Bool
    let enroll: () -> Void
    let verify: () -> Void
    let reset: () -> Void

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: profileExists ? "checkmark.seal.fill" : "person.badge.plus")
                        .foregroundStyle(profileExists ? .green : .secondary)
                    Text(status)
                        .lineLimit(2)
                    Spacer()
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                ToggleLine(
                    "Filter dictation to my voice",
                    systemImage: "person.crop.circle.badge.checkmark",
                    isOn: $config.voiceprintEnabled
                )
                SliderLine(
                    "Voice threshold",
                    value: String(format: "%.2f", config.voiceprintThreshold),
                    systemImage: "slider.horizontal.3"
                ) {
                    Slider(value: $config.voiceprintThreshold, in: 0.45 ... 0.95, step: 0.01)
                        .frame(width: 190)
                }
                .disabled(!config.voiceprintEnabled || !profileExists)
            } header: {
                Text("Voice Filtering")
            } footer: {
                Text(config.voiceprintEnabled
                    ? "Higher values are looser and keep more speech; lower values are stricter."
                    : "Voice filtering is off, so Mimi transcribes the entire recording.")
            }

            Section {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Read twice while enrolling:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("“\(VoiceprintPrototype.enrollmentPrompt)”")
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Enroll", action: enroll)
                        .disabled(busy)
                    Button("Verify", action: verify)
                        .disabled(busy || !profileExists)
                    Button("Reset", role: .destructive, action: reset)
                        .disabled(busy || !profileExists)
                }
            } header: {
                Text("Enrollment")
            } footer: {
                Text("Mimi keeps matching speaker segments, then transcribes only those segments.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettingsPane: View {
    @Binding var config: MimiConfig
    let configErrorText: String?
    let openConfigFile: () -> Void
    let reloadConfig: () -> Void

    var body: some View {
        Form {
            Section {
                PickerLine("Stop detection", systemImage: "waveform.and.magnifyingglass") {
                    Picker("Stop detection", selection: $config.silenceDetectionMode) {
                        ForEach(SilenceDetectionMode.allCases, id: \.self) { mode in
                            Text(mode.displayName)
                                .tag(mode)
                                .disabled(!config.preferredBackend.capabilities.supportsSilenceDetectionMode(mode))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                SliderLine(
                    "Noise floor",
                    value: "\(Int(config.silenceThresholdDBFS)) dBFS",
                    systemImage: "dial.low"
                ) {
                    Slider(value: $config.silenceThresholdDBFS, in: -65 ... -15, step: 1)
                        .frame(width: 190)
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
                    .frame(width: 190)
                }
            } header: {
                Text("Silence Detection")
            }

            Section {
                LabeledContent("Location") {
                    Text("~/.config/mimi/config.json")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }

                HStack {
                    Button("Open Config…", action: openConfigFile)
                    Button("Reload", action: reloadConfig)
                    Spacer()
                }

                if let configErrorText {
                    Label(configErrorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Config File")
            } footer: {
                Text("Expert timing, vocabulary, and preset collection options remain available in the canonical config file.")
            }
        }
        .formStyle(.grouped)
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
            get: { AudioInputDevice.validSelection(selectedID, in: devices) ?? "" },
            set: { selectedID = $0.isEmpty ? nil : $0 }
        )
    }

    private var selectedDeviceMissing: Bool {
        guard let selectedID else { return false }
        return !devices.contains { $0.id == selectedID }
    }

    private var automaticDeviceName: String? {
        let automaticID = AudioInputDevice.automaticSelection(
            defaultInputDeviceID: AudioInputDevice.defaultInputDeviceUID(),
            in: devices
        )
        return devices.first(where: { $0.id == automaticID })?.name
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
                    Text(automaticDeviceName.map { "Automatic — \($0)" } ?? "Automatic").tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .help("Automatic uses the built-in microphone when the system default is Bluetooth, preserving headphone playback and media controls.")
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh input devices")
            }
            if selectedDeviceMissing {
                Label("Selected microphone is not connected.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct PasteSettingsEditor: View {
    @Binding var settings: PasteSettings
    let beforeDelayField: SettingsField
    let afterDelayField: SettingsField
    let focusedField: FocusState<SettingsField?>.Binding
    let disabled: Bool
    let onRecordingChanged: (Bool) -> Void

    var body: some View {
        OptionalShortcutRecorderRow(
            title: "Before paste",
            systemImage: "arrow.right.to.line",
            shortcut: $settings.prePasteKeystroke,
            disabled: disabled,
            onRecordingChanged: onRecordingChanged
        )
        OptionalShortcutRecorderRow(
            title: "After paste",
            systemImage: "arrow.left.to.line",
            shortcut: $settings.postPasteKeystroke,
            disabled: disabled,
            onRecordingChanged: onRecordingChanged
        )
        PasteDelayLine(
            beforeMilliseconds: $settings.prePasteDelayMilliseconds,
            afterMilliseconds: $settings.postPasteDelayMilliseconds,
            beforeField: beforeDelayField,
            afterField: afterDelayField,
            focusedField: focusedField,
            disabled: disabled
        )
    }
}

private struct PasteDelayLine: View {
    @Binding var beforeMilliseconds: Int
    @Binding var afterMilliseconds: Int
    let beforeField: SettingsField
    let afterField: SettingsField
    let focusedField: FocusState<SettingsField?>.Binding
    let disabled: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text("Delays")
            Spacer(minLength: 8)
            DelayField(
                title: "Before",
                value: $beforeMilliseconds,
                field: beforeField,
                focusedField: focusedField
            )
            DelayField(
                title: "After",
                value: $afterMilliseconds,
                field: afterField,
                focusedField: focusedField
            )
        }
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }
}

private struct DelayField: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let field: SettingsField
    let focusedField: FocusState<SettingsField?>.Binding

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, value: $value, format: .number)
                .labelsHidden()
                .focused(focusedField, equals: field)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
            Text("ms")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            ShortcutRecorderButton(
                disabled: disabled,
                capturesEscape: false,
                onCapture: { self.shortcut = $0 },
                onRecordingChanged: onRecordingChanged
            )
        }
        .opacity(disabled ? 0.45 : 1)
    }
}

private struct OptionalShortcutRecorderRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    @Binding var shortcut: MimiShortcut?
    let disabled: Bool
    let onRecordingChanged: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
            Spacer()
            Group {
                if let shortcut {
                    Text(shortcut.displayName)
                } else {
                    Text("None")
                }
            }
            .font(.system(.body, design: .rounded).weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            if shortcut != nil {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Clear keystroke")
                .controlSize(.small)
                .disabled(disabled)
            }
            ShortcutRecorderButton(
                disabled: disabled,
                capturesEscape: true,
                onCapture: { self.shortcut = $0 },
                onRecordingChanged: onRecordingChanged
            )
        }
        .opacity(disabled ? 0.45 : 1)
    }
}

private struct ShortcutRecorderButton: View {
    let disabled: Bool
    let capturesEscape: Bool
    let onCapture: (MimiShortcut) -> Void
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
                    capturesEscape: capturesEscape,
                    onCapture: onCapture,
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

    func start(
        capturesEscape: Bool,
        onCapture: @escaping (MimiShortcut) -> Void,
        onFinish: @escaping () -> Void
    ) {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                if event.keyCode == 53, !capturesEscape {
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
    let open: () -> Void

    init(_ title: String, systemImage: String, open: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.open = open
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
                .frame(width: 18)
            Text(title)
            Spacer()
            Text("Required")
                .font(.caption)
                .foregroundStyle(.orange)
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
