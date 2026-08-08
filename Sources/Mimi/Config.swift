import AppKit
import Foundation

public struct MimiShortcut: Codable, Equatable, Sendable {
    public var keyCode: Int
    public var modifierFlagsRaw: UInt

    public init(keyCode: Int, modifierFlagsRaw: UInt) {
        self.keyCode = keyCode
        self.modifierFlagsRaw = modifierFlagsRaw
    }

    public static let rightCommand = MimiShortcut(
        keyCode: 54,
        modifierFlagsRaw: NSEvent.ModifierFlags.command.rawValue
    )

    public static let returnKey = MimiShortcut(keyCode: 36, modifierFlagsRaw: 0)

    public static let ambientToggleDefault = MimiShortcut(
        keyCode: 0, // A
        modifierFlagsRaw: NSEvent.ModifierFlags([.control, .option]).rawValue
    )

    public static let correctionDefault = MimiShortcut(
        keyCode: 8, // C
        modifierFlagsRaw: NSEvent.ModifierFlags([.control, .option]).rawValue
    )

    public static let pastePresetDefault = MimiShortcut(
        keyCode: 35, // P
        modifierFlagsRaw: NSEvent.ModifierFlags([.control, .option]).rawValue
    )

    static func legacySingleKey(keyCode: Int) -> MimiShortcut {
        MimiShortcut(
            keyCode: keyCode,
            modifierFlagsRaw: modifierFlagRaw(forKeyCode: keyCode) ?? 0
        )
    }

    private static func modifierFlagRaw(forKeyCode keyCode: Int) -> UInt? {
        switch keyCode {
        case 54, 55:
            NSEvent.ModifierFlags.command.rawValue
        case 58, 61:
            NSEvent.ModifierFlags.option.rawValue
        case 59, 62:
            NSEvent.ModifierFlags.control.rawValue
        case 56, 60:
            NSEvent.ModifierFlags.shift.rawValue
        case 63:
            NSEvent.ModifierFlags.function.rawValue
        default:
            nil
        }
    }
}

public struct PasteSettings: Codable, Equatable, Sendable {
    public var prePasteKeystroke: MimiShortcut?
    public var postPasteKeystroke: MimiShortcut?
    public var prePasteDelayMilliseconds: Int
    public var postPasteDelayMilliseconds: Int

    public init(
        prePasteKeystroke: MimiShortcut?,
        postPasteKeystroke: MimiShortcut?,
        prePasteDelayMilliseconds: Int,
        postPasteDelayMilliseconds: Int
    ) {
        self.prePasteKeystroke = prePasteKeystroke
        self.postPasteKeystroke = postPasteKeystroke
        self.prePasteDelayMilliseconds = prePasteDelayMilliseconds
        self.postPasteDelayMilliseconds = postPasteDelayMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        prePasteKeystroke = try container.decodeIfPresent(MimiShortcut.self, forKey: .prePasteKeystroke)
        postPasteKeystroke = try container.decodeIfPresent(MimiShortcut.self, forKey: .postPasteKeystroke)
        prePasteDelayMilliseconds = try container.decodeIfPresent(Int.self, forKey: .prePasteDelayMilliseconds) ?? 150
        postPasteDelayMilliseconds = try container.decodeIfPresent(Int.self, forKey: .postPasteDelayMilliseconds) ?? 150
    }

    public static let defaults = PasteSettings(
        prePasteKeystroke: nil,
        postPasteKeystroke: .returnKey,
        prePasteDelayMilliseconds: 150,
        postPasteDelayMilliseconds: 150
    )

    static func preset(pre: MimiShortcut?, post: MimiShortcut?) -> PasteSettings {
        PasteSettings(
            prePasteKeystroke: pre,
            postPasteKeystroke: post,
            prePasteDelayMilliseconds: defaults.prePasteDelayMilliseconds,
            postPasteDelayMilliseconds: defaults.postPasteDelayMilliseconds
        )
    }
}

/// Named pre/post-paste keystroke set for one target app, selected by shortcut or in Settings.
public struct PastePreset: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var paste: PasteSettings

    public var id: String { name }

    public init(name: String, paste: PasteSettings) {
        self.name = name
        self.paste = paste
    }

    public static let manualName = "Manual"

    public static let defaults: [PastePreset] = [
        PastePreset(name: "Terminal agent", paste: .preset(pre: nil, post: .returnKey)),
        PastePreset(name: "RevDiff", paste: .preset(pre: .returnKey, post: .returnKey)),
        PastePreset(
            name: "TUICR",
            paste: .preset(pre: MimiShortcut(keyCode: 8, modifierFlagsRaw: 0), post: .returnKey)
        )
    ]
}

private struct LegacyVocabularyEntry: Decodable {
    let writtenForm: String
    let spokenAliases: [String]
    let isEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case writtenForm
        case spokenAliases
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        writtenForm = try container.decode(String.self, forKey: .writtenForm)
        spokenAliases = try container.decodeIfPresent([String].self, forKey: .spokenAliases) ?? []
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    var pairing: VocabularyEntry? {
        guard isEnabled else { return nil }
        let sources = spokenAliases.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return VocabularyEntry(from: sources, to: writtenForm)
    }
}

public enum ASRBackend: String, CaseIterable, Codable, Equatable, Sendable {
    case mlxParakeetV2
    case appleSpeechTranscriber

    var displayName: String {
        switch self {
        case .mlxParakeetV2:
            "MLX Parakeet v2"
        case .appleSpeechTranscriber:
            "Apple SpeechTranscriber"
        }
    }
}

public enum SilenceDetectionMode: String, CaseIterable, Codable, Equatable, Sendable {
    case audioLevel
    case speechActivity

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .audioLevel
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch self {
        case .audioLevel:
            "Audio level (RMS)"
        case .speechActivity:
            "Speech activity (Apple VAD)"
        }
    }
}

// TODO(ponytail): collapse this into direct ASRBackend computed vars if capabilities stay this small.
public struct ASRBackendCapabilities: Equatable, Sendable {
    public let supportsAmbient: Bool
    public let supportedSilenceDetectionModes: [SilenceDetectionMode]
    public let defaultSilenceDetectionMode: SilenceDetectionMode
    public let supportsStreamingTranscription: Bool

    public func supportsSilenceDetectionMode(_ mode: SilenceDetectionMode) -> Bool {
        supportedSilenceDetectionModes.contains(mode)
    }

    public func normalizeAmbientModeEnabled(_ enabled: Bool) -> Bool {
        supportsAmbient && enabled
    }

    public func normalizeSilenceDetectionMode(_ mode: SilenceDetectionMode) -> SilenceDetectionMode {
        supportsSilenceDetectionMode(mode) ? mode : defaultSilenceDetectionMode
    }

    public func usesSpeechActivityStop(_ mode: SilenceDetectionMode) -> Bool {
        supportsSilenceDetectionMode(.speechActivity) && mode == .speechActivity
    }

    public func usesStreamingTranscription(isAmbient: Bool, silenceDetectionMode: SilenceDetectionMode) -> Bool {
        supportsStreamingTranscription && (isAmbient || usesSpeechActivityStop(silenceDetectionMode))
    }
}

extension ASRBackend {
    public var capabilities: ASRBackendCapabilities {
        switch self {
        case .mlxParakeetV2:
            ASRBackendCapabilities(
                supportsAmbient: false,
                supportedSilenceDetectionModes: [.audioLevel],
                defaultSilenceDetectionMode: .audioLevel,
                supportsStreamingTranscription: false
            )
        case .appleSpeechTranscriber:
            ASRBackendCapabilities(
                supportsAmbient: true,
                supportedSilenceDetectionModes: [.audioLevel, .speechActivity],
                defaultSilenceDetectionMode: .audioLevel,
                supportsStreamingTranscription: true
            )
        }
    }
}

public struct MimiConfig: Codable, Equatable, Sendable {
    private static let defaultsKey = "MimiConfig.v1"
    private static let appleStreamingMigrationKey = "MimiConfig.appleSpeechDefault.v1"

    private enum CodingKeys: String, CodingKey {
        case preferredBackend
        case silenceAutoStopEnabled
        case silenceThresholdDBFS
        case silenceDurationMilliseconds
        case silenceDetectionMode
        case minUtteranceMilliseconds
        case preRollMilliseconds
        case tapThresholdMilliseconds
        case hotkeyKeyCode
        case dictationShortcut
        case inputDeviceID
        case ambientModeEnabled
        case ambientToggleShortcut
        case correctionShortcut
        case dictationPasteSettings
        case ambientPasteSettings
        case pastePresets
        case activePastePresetName
        case pastePresetShortcut
        case ambientPrePasteKeystroke
        case ambientPostPasteKeystroke
        case ambientStartKeystroke
        case ambientEndKeystroke
        case ambientPressEnterOnStart
        case pressEnterAfterPaste
        case prePasteKeystrokeDelayMilliseconds
        case postPasteKeystrokeDelayMilliseconds
        case postPasteEnterDelayMilliseconds
        case showLiveTranscript
        case fillerCleanupEnabled
        case vocabulary
        case vocabularyEntries
        case voiceprintEnabled
        case voiceprintThreshold
        case modelDownloadEnabled
    }

    public var preferredBackend: ASRBackend
    public var silenceAutoStopEnabled: Bool
    public var silenceThresholdDBFS: Double
    public var silenceDurationMilliseconds: Int
    public var silenceDetectionMode: SilenceDetectionMode
    public var minUtteranceMilliseconds: Int
    public var preRollMilliseconds: Int
    public var tapThresholdMilliseconds: Int
    // TODO(ponytail): remove stored legacy mirror; decode hotkeyKeyCode locally only for old configs.
    public var hotkeyKeyCode: Int
    public var dictationShortcut: MimiShortcut
    public var inputDeviceID: String?
    public var ambientModeEnabled: Bool
    public var ambientToggleShortcut: MimiShortcut
    public var correctionShortcut: MimiShortcut
    public var dictationPasteSettings: PasteSettings
    public var ambientPasteSettings: PasteSettings
    public var pastePresets: [PastePreset]
    public var activePastePresetName: String?
    public var pastePresetShortcut: MimiShortcut
    public var showLiveTranscript: Bool
    public var fillerCleanupEnabled: Bool
    public var vocabulary: [VocabularyEntry]
    public var voiceprintEnabled: Bool
    public var voiceprintThreshold: Double
    // TODO(ponytail): delete if no model-download toggle UI/runtime behavior appears.
    public var modelDownloadEnabled: Bool

    public static let defaults = MimiConfig(
        preferredBackend: .appleSpeechTranscriber,
        silenceAutoStopEnabled: true,
        silenceThresholdDBFS: -50,
        silenceDurationMilliseconds: 2_000,
        silenceDetectionMode: .audioLevel,
        minUtteranceMilliseconds: 350,
        preRollMilliseconds: 700,
        tapThresholdMilliseconds: 220,
        hotkeyKeyCode: 54, // Right Command on Apple keyboards.
        dictationShortcut: .rightCommand,
        inputDeviceID: nil,
        ambientModeEnabled: false,
        ambientToggleShortcut: .ambientToggleDefault,
        correctionShortcut: .correctionDefault,
        dictationPasteSettings: .defaults,
        ambientPasteSettings: .defaults,
        pastePresets: PastePreset.defaults,
        activePastePresetName: nil,
        pastePresetShortcut: .pastePresetDefault,
        showLiveTranscript: true,
        fillerCleanupEnabled: true,
        vocabulary: [],
        voiceprintEnabled: true,
        voiceprintThreshold: 0.78,
        modelDownloadEnabled: true
    )

    public init(
        preferredBackend: ASRBackend,
        silenceAutoStopEnabled: Bool,
        silenceThresholdDBFS: Double,
        silenceDurationMilliseconds: Int,
        silenceDetectionMode: SilenceDetectionMode = .audioLevel,
        minUtteranceMilliseconds: Int,
        preRollMilliseconds: Int,
        tapThresholdMilliseconds: Int,
        hotkeyKeyCode: Int,
        dictationShortcut: MimiShortcut = .rightCommand,
        inputDeviceID: String? = nil,
        ambientModeEnabled: Bool,
        ambientToggleShortcut: MimiShortcut = .ambientToggleDefault,
        correctionShortcut: MimiShortcut = .correctionDefault,
        dictationPasteSettings: PasteSettings = .defaults,
        ambientPasteSettings: PasteSettings = .defaults,
        pastePresets: [PastePreset] = PastePreset.defaults,
        activePastePresetName: String? = nil,
        pastePresetShortcut: MimiShortcut = .pastePresetDefault,
        showLiveTranscript: Bool = true,
        fillerCleanupEnabled: Bool = true,
        vocabulary: [VocabularyEntry] = [],
        voiceprintEnabled: Bool = true,
        voiceprintThreshold: Double = 0.78,
        modelDownloadEnabled: Bool
    ) {
        self.preferredBackend = preferredBackend
        self.silenceAutoStopEnabled = silenceAutoStopEnabled
        self.silenceThresholdDBFS = silenceThresholdDBFS
        self.silenceDurationMilliseconds = silenceDurationMilliseconds
        self.silenceDetectionMode = silenceDetectionMode
        self.minUtteranceMilliseconds = minUtteranceMilliseconds
        self.preRollMilliseconds = preRollMilliseconds
        self.tapThresholdMilliseconds = tapThresholdMilliseconds
        self.hotkeyKeyCode = hotkeyKeyCode
        self.dictationShortcut = dictationShortcut
        self.inputDeviceID = inputDeviceID
        self.ambientModeEnabled = ambientModeEnabled
        self.ambientToggleShortcut = ambientToggleShortcut
        self.correctionShortcut = correctionShortcut
        self.dictationPasteSettings = dictationPasteSettings
        self.ambientPasteSettings = ambientPasteSettings
        self.pastePresets = pastePresets
        self.activePastePresetName = activePastePresetName
        self.pastePresetShortcut = pastePresetShortcut
        self.showLiveTranscript = showLiveTranscript
        self.fillerCleanupEnabled = fillerCleanupEnabled
        self.vocabulary = vocabulary
        self.voiceprintEnabled = voiceprintEnabled
        self.voiceprintThreshold = voiceprintThreshold
        self.modelDownloadEnabled = modelDownloadEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferredBackend = try container.decodeIfPresent(ASRBackend.self, forKey: .preferredBackend) ?? Self.defaults.preferredBackend
        silenceAutoStopEnabled = try container.decodeIfPresent(Bool.self, forKey: .silenceAutoStopEnabled) ?? Self.defaults.silenceAutoStopEnabled
        silenceThresholdDBFS = try container.decodeIfPresent(Double.self, forKey: .silenceThresholdDBFS) ?? Self.defaults.silenceThresholdDBFS
        silenceDurationMilliseconds = try container.decodeIfPresent(Int.self, forKey: .silenceDurationMilliseconds) ?? Self.defaults.silenceDurationMilliseconds
        silenceDetectionMode = try container.decodeIfPresent(SilenceDetectionMode.self, forKey: .silenceDetectionMode) ?? Self.defaults.silenceDetectionMode
        minUtteranceMilliseconds = try container.decodeIfPresent(Int.self, forKey: .minUtteranceMilliseconds) ?? Self.defaults.minUtteranceMilliseconds
        preRollMilliseconds = try container.decodeIfPresent(Int.self, forKey: .preRollMilliseconds) ?? Self.defaults.preRollMilliseconds
        tapThresholdMilliseconds = try container.decodeIfPresent(Int.self, forKey: .tapThresholdMilliseconds) ?? Self.defaults.tapThresholdMilliseconds
        hotkeyKeyCode = try container.decodeIfPresent(Int.self, forKey: .hotkeyKeyCode) ?? Self.defaults.hotkeyKeyCode
        dictationShortcut = try container.decodeIfPresent(MimiShortcut.self, forKey: .dictationShortcut)
            ?? MimiShortcut.legacySingleKey(keyCode: hotkeyKeyCode)
        inputDeviceID = try container.decodeIfPresent(String.self, forKey: .inputDeviceID)
        ambientModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .ambientModeEnabled) ?? Self.defaults.ambientModeEnabled
        ambientToggleShortcut = try container.decodeIfPresent(MimiShortcut.self, forKey: .ambientToggleShortcut) ?? Self.defaults.ambientToggleShortcut
        correctionShortcut = try container.decodeIfPresent(MimiShortcut.self, forKey: .correctionShortcut) ?? Self.defaults.correctionShortcut

        let legacyPrePasteDelay = try container.decodeIfPresent(Int.self, forKey: .prePasteKeystrokeDelayMilliseconds)
            ?? PasteSettings.defaults.prePasteDelayMilliseconds
        let legacyPostPasteDelay = try container.decodeIfPresent(Int.self, forKey: .postPasteKeystrokeDelayMilliseconds)
            ?? container.decodeIfPresent(Int.self, forKey: .postPasteEnterDelayMilliseconds)
            ?? PasteSettings.defaults.postPasteDelayMilliseconds

        if let settings = try container.decodeIfPresent(PasteSettings.self, forKey: .dictationPasteSettings) {
            dictationPasteSettings = settings
        } else {
            let legacyPressReturn = try container.decodeIfPresent(Bool.self, forKey: .pressEnterAfterPaste) ?? true
            dictationPasteSettings = PasteSettings(
                prePasteKeystroke: nil,
                postPasteKeystroke: legacyPressReturn ? .returnKey : nil,
                prePasteDelayMilliseconds: legacyPrePasteDelay,
                postPasteDelayMilliseconds: legacyPostPasteDelay
            )
        }

        if let settings = try container.decodeIfPresent(PasteSettings.self, forKey: .ambientPasteSettings) {
            ambientPasteSettings = settings
        } else {
            let prePasteKeystroke: MimiShortcut?
            if container.contains(.ambientPrePasteKeystroke) {
                prePasteKeystroke = try container.decodeIfPresent(MimiShortcut.self, forKey: .ambientPrePasteKeystroke)
            } else if container.contains(.ambientStartKeystroke) {
                prePasteKeystroke = try container.decodeIfPresent(MimiShortcut.self, forKey: .ambientStartKeystroke)
            } else {
                let legacyPressReturn = try container.decodeIfPresent(Bool.self, forKey: .ambientPressEnterOnStart) ?? false
                prePasteKeystroke = legacyPressReturn ? .returnKey : nil
            }

            let postPasteKeystroke: MimiShortcut?
            if container.contains(.ambientPostPasteKeystroke) {
                postPasteKeystroke = try container.decodeIfPresent(MimiShortcut.self, forKey: .ambientPostPasteKeystroke)
            } else if container.contains(.ambientEndKeystroke) {
                postPasteKeystroke = try container.decodeIfPresent(MimiShortcut.self, forKey: .ambientEndKeystroke)
            } else {
                postPasteKeystroke = .returnKey
            }

            ambientPasteSettings = PasteSettings(
                prePasteKeystroke: prePasteKeystroke,
                postPasteKeystroke: postPasteKeystroke,
                prePasteDelayMilliseconds: legacyPrePasteDelay,
                postPasteDelayMilliseconds: legacyPostPasteDelay
            )
        }
        pastePresets = try container.decodeIfPresent([PastePreset].self, forKey: .pastePresets) ?? Self.defaults.pastePresets
        activePastePresetName = try container.decodeIfPresent(String.self, forKey: .activePastePresetName)
        pastePresetShortcut = try container.decodeIfPresent(MimiShortcut.self, forKey: .pastePresetShortcut) ?? Self.defaults.pastePresetShortcut
        showLiveTranscript = try container.decodeIfPresent(Bool.self, forKey: .showLiveTranscript) ?? Self.defaults.showLiveTranscript
        fillerCleanupEnabled = try container.decodeIfPresent(Bool.self, forKey: .fillerCleanupEnabled) ?? Self.defaults.fillerCleanupEnabled
        if let decodedVocabulary = try container.decodeIfPresent([VocabularyEntry].self, forKey: .vocabulary) {
            vocabulary = decodedVocabulary
        } else {
            vocabulary = try container.decodeIfPresent([LegacyVocabularyEntry].self, forKey: .vocabularyEntries)?
                .compactMap(\.pairing) ?? []
        }
        voiceprintEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceprintEnabled) ?? Self.defaults.voiceprintEnabled
        voiceprintThreshold = try container.decodeIfPresent(Double.self, forKey: .voiceprintThreshold) ?? Self.defaults.voiceprintThreshold
        modelDownloadEnabled = try container.decodeIfPresent(Bool.self, forKey: .modelDownloadEnabled) ?? Self.defaults.modelDownloadEnabled
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preferredBackend, forKey: .preferredBackend)
        try container.encode(silenceAutoStopEnabled, forKey: .silenceAutoStopEnabled)
        try container.encode(silenceThresholdDBFS, forKey: .silenceThresholdDBFS)
        try container.encode(silenceDurationMilliseconds, forKey: .silenceDurationMilliseconds)
        try container.encode(silenceDetectionMode, forKey: .silenceDetectionMode)
        try container.encode(minUtteranceMilliseconds, forKey: .minUtteranceMilliseconds)
        try container.encode(preRollMilliseconds, forKey: .preRollMilliseconds)
        try container.encode(tapThresholdMilliseconds, forKey: .tapThresholdMilliseconds)
        try container.encode(dictationShortcut.keyCode, forKey: .hotkeyKeyCode)
        try container.encode(dictationShortcut, forKey: .dictationShortcut)
        try container.encodeIfPresent(inputDeviceID, forKey: .inputDeviceID)
        try container.encode(ambientModeEnabled, forKey: .ambientModeEnabled)
        try container.encode(ambientToggleShortcut, forKey: .ambientToggleShortcut)
        try container.encode(correctionShortcut, forKey: .correctionShortcut)
        try container.encode(dictationPasteSettings, forKey: .dictationPasteSettings)
        try container.encode(ambientPasteSettings, forKey: .ambientPasteSettings)
        try container.encode(pastePresets, forKey: .pastePresets)
        try container.encodeIfPresent(activePastePresetName, forKey: .activePastePresetName)
        try container.encode(pastePresetShortcut, forKey: .pastePresetShortcut)
        try container.encode(ambientPasteSettings.prePasteKeystroke, forKey: .ambientPrePasteKeystroke)
        try container.encode(ambientPasteSettings.postPasteKeystroke, forKey: .ambientPostPasteKeystroke)
        try container.encode(ambientPasteSettings.prePasteKeystroke, forKey: .ambientStartKeystroke)
        try container.encode(ambientPasteSettings.postPasteKeystroke, forKey: .ambientEndKeystroke)
        try container.encode(ambientPasteSettings.prePasteKeystroke == .returnKey, forKey: .ambientPressEnterOnStart)
        try container.encode(dictationPasteSettings.postPasteKeystroke == .returnKey, forKey: .pressEnterAfterPaste)
        try container.encode(ambientPasteSettings.prePasteDelayMilliseconds, forKey: .prePasteKeystrokeDelayMilliseconds)
        try container.encode(ambientPasteSettings.postPasteDelayMilliseconds, forKey: .postPasteKeystrokeDelayMilliseconds)
        try container.encode(dictationPasteSettings.postPasteDelayMilliseconds, forKey: .postPasteEnterDelayMilliseconds)
        try container.encode(showLiveTranscript, forKey: .showLiveTranscript)
        try container.encode(fillerCleanupEnabled, forKey: .fillerCleanupEnabled)
        try container.encode(vocabulary, forKey: .vocabulary)
        try container.encode(voiceprintEnabled, forKey: .voiceprintEnabled)
        try container.encode(voiceprintThreshold, forKey: .voiceprintThreshold)
        try container.encode(modelDownloadEnabled, forKey: .modelDownloadEnabled)
    }

    public static func load(userDefaults: UserDefaults = .standard) -> MimiConfig {
        guard let data = userDefaults.data(forKey: defaultsKey),
              var config = try? JSONDecoder().decode(MimiConfig.self, from: data)
        else { return .defaults }
        var migrated = false
        if config.silenceThresholdDBFS == -38 {
            config.silenceThresholdDBFS = Self.defaults.silenceThresholdDBFS
            migrated = true
        }
        if !userDefaults.bool(forKey: appleStreamingMigrationKey) {
            config.preferredBackend = .appleSpeechTranscriber
            userDefaults.set(true, forKey: appleStreamingMigrationKey)
            migrated = true
        }
        if config.normalizeForBackend() {
            migrated = true
        }
        if migrated {
            config.save(userDefaults: userDefaults)
        }
        return config
    }

    @discardableResult
    public mutating func normalizeForBackend() -> Bool {
        let oldValue = self
        let capabilities = preferredBackend.capabilities
        ambientModeEnabled = capabilities.normalizeAmbientModeEnabled(ambientModeEnabled)
        silenceDetectionMode = capabilities.normalizeSilenceDetectionMode(silenceDetectionMode)
        voiceprintThreshold = min(0.95, max(0.45, voiceprintThreshold))
        if activePastePresetName != nil, activePastePreset == nil {
            activePastePresetName = nil
        }
        return self != oldValue
    }

    /// Paste keystrokes in effect: active preset wins over the per-mode settings.
    public var activePastePreset: PastePreset? {
        guard let activePastePresetName else { return nil }
        return pastePresets.first { $0.name == activePastePresetName }
    }

    public var activePastePresetLabel: String {
        activePastePreset?.name ?? PastePreset.manualName
    }

    public func pasteSettings(isAmbient: Bool) -> PasteSettings {
        activePastePreset?.paste ?? (isAmbient ? ambientPasteSettings : dictationPasteSettings)
    }

    /// Advances Manual → each preset → Manual.
    public mutating func cyclePastePreset() {
        let names: [String?] = [nil] + pastePresets.map(\.name)
        let index = names.firstIndex(of: activePastePreset?.name) ?? 0
        activePastePresetName = names[(index + 1) % names.count]
    }

    public func normalizedForBackend() -> MimiConfig {
        var copy = self
        _ = copy.normalizeForBackend()
        return copy
    }

    public func save(userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
