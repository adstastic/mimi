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
    case automatic
    case audioLevel
    case speechActivity

    static let visibleCases: [SilenceDetectionMode] = [.audioLevel, .speechActivity]

    var displayName: String {
        switch self {
        case .automatic:
            "Automatic"
        case .audioLevel:
            "Audio level (RMS)"
        case .speechActivity:
            "Speech activity (Apple VAD)"
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
        case pressEnterAfterPaste
        case postPasteEnterDelayMilliseconds
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
    public var hotkeyKeyCode: Int
    public var dictationShortcut: MimiShortcut
    public var inputDeviceID: String?
    public var ambientModeEnabled: Bool
    public var ambientToggleShortcut: MimiShortcut
    public var pressEnterAfterPaste: Bool
    public var postPasteEnterDelayMilliseconds: Int
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
        pressEnterAfterPaste: true,
        postPasteEnterDelayMilliseconds: 150,
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
        pressEnterAfterPaste: Bool,
        postPasteEnterDelayMilliseconds: Int,
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
        self.pressEnterAfterPaste = pressEnterAfterPaste
        self.postPasteEnterDelayMilliseconds = postPasteEnterDelayMilliseconds
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
        pressEnterAfterPaste = try container.decodeIfPresent(Bool.self, forKey: .pressEnterAfterPaste) ?? Self.defaults.pressEnterAfterPaste
        postPasteEnterDelayMilliseconds = try container.decodeIfPresent(Int.self, forKey: .postPasteEnterDelayMilliseconds) ?? Self.defaults.postPasteEnterDelayMilliseconds
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
        try container.encode(pressEnterAfterPaste, forKey: .pressEnterAfterPaste)
        try container.encode(postPasteEnterDelayMilliseconds, forKey: .postPasteEnterDelayMilliseconds)
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
        if preferredBackend == .mlxParakeetV2 {
            ambientModeEnabled = false
            silenceDetectionMode = .audioLevel
        } else if silenceDetectionMode == .automatic {
            silenceDetectionMode = ambientModeEnabled ? .speechActivity : .audioLevel
        }
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
