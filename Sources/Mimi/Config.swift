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

    public static let defaults = PasteSettings(
        prePasteKeystroke: nil,
        postPasteKeystroke: .returnKey,
        prePasteDelayMilliseconds: 150,
        postPasteDelayMilliseconds: 150
    )
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
        case dictationPasteSettings
        case ambientPasteSettings
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
    public var dictationPasteSettings: PasteSettings
    public var ambientPasteSettings: PasteSettings
    public var showLiveTranscript: Bool
    public var fillerCleanupEnabled: Bool
    public var vocabularyEntries: [VocabularyEntry]
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
        dictationPasteSettings: .defaults,
        ambientPasteSettings: .defaults,
        showLiveTranscript: true,
        fillerCleanupEnabled: true,
        vocabularyEntries: [],
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
        dictationPasteSettings: PasteSettings = .defaults,
        ambientPasteSettings: PasteSettings = .defaults,
        showLiveTranscript: Bool = true,
        fillerCleanupEnabled: Bool = true,
        vocabularyEntries: [VocabularyEntry] = [],
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
        self.dictationPasteSettings = dictationPasteSettings
        self.ambientPasteSettings = ambientPasteSettings
        self.showLiveTranscript = showLiveTranscript
        self.fillerCleanupEnabled = fillerCleanupEnabled
        self.vocabularyEntries = vocabularyEntries
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
        showLiveTranscript = try container.decodeIfPresent(Bool.self, forKey: .showLiveTranscript) ?? Self.defaults.showLiveTranscript
        fillerCleanupEnabled = try container.decodeIfPresent(Bool.self, forKey: .fillerCleanupEnabled) ?? Self.defaults.fillerCleanupEnabled
        vocabularyEntries = try container.decodeIfPresent([VocabularyEntry].self, forKey: .vocabularyEntries) ?? []
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
        try container.encode(dictationPasteSettings, forKey: .dictationPasteSettings)
        try container.encode(ambientPasteSettings, forKey: .ambientPasteSettings)
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
        try container.encode(vocabularyEntries, forKey: .vocabularyEntries)
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
        return self != oldValue
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
