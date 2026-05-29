import AppKit
import Foundation

public struct SokkiShortcut: Codable, Equatable, Sendable {
    public var keyCode: Int
    public var modifierFlagsRaw: UInt

    public init(keyCode: Int, modifierFlagsRaw: UInt) {
        self.keyCode = keyCode
        self.modifierFlagsRaw = modifierFlagsRaw
    }

    public static let rightCommand = SokkiShortcut(
        keyCode: 54,
        modifierFlagsRaw: NSEvent.ModifierFlags.command.rawValue
    )

    public static let ambientToggleDefault = SokkiShortcut(
        keyCode: 0, // A
        modifierFlagsRaw: NSEvent.ModifierFlags([.control, .option]).rawValue
    )

    static func legacySingleKey(keyCode: Int) -> SokkiShortcut {
        SokkiShortcut(
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

public struct SokkiConfig: Codable, Equatable, Sendable {
    private static let defaultsKey = "SokkiConfig.v4"
    private static let appleStreamingMigrationKey = "SokkiConfig.appleStreamingDefault.v1"

    private enum CodingKeys: String, CodingKey {
        case preferredBackend
        case silenceAutoStopEnabled
        case silenceThresholdDBFS
        case silenceDurationMilliseconds
        case minUtteranceMilliseconds
        case preRollMilliseconds
        case tapThresholdMilliseconds
        case hotkeyKeyCode
        case dictationShortcut
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
    public var minUtteranceMilliseconds: Int
    public var preRollMilliseconds: Int
    public var tapThresholdMilliseconds: Int
    public var hotkeyKeyCode: Int
    public var dictationShortcut: SokkiShortcut
    public var ambientModeEnabled: Bool
    public var ambientToggleShortcut: SokkiShortcut
    public var pressEnterAfterPaste: Bool
    public var postPasteEnterDelayMilliseconds: Int
    public var modelDownloadEnabled: Bool

    public static let defaults = SokkiConfig(
        preferredBackend: .appleSpeechTranscriber,
        silenceAutoStopEnabled: true,
        silenceThresholdDBFS: -50,
        silenceDurationMilliseconds: 2_000,
        minUtteranceMilliseconds: 350,
        preRollMilliseconds: 700,
        tapThresholdMilliseconds: 220,
        hotkeyKeyCode: 54, // Right Command on Apple keyboards.
        dictationShortcut: .rightCommand,
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
        minUtteranceMilliseconds: Int,
        preRollMilliseconds: Int,
        tapThresholdMilliseconds: Int,
        hotkeyKeyCode: Int,
        dictationShortcut: SokkiShortcut = .rightCommand,
        ambientModeEnabled: Bool,
        ambientToggleShortcut: SokkiShortcut = .ambientToggleDefault,
        pressEnterAfterPaste: Bool,
        postPasteEnterDelayMilliseconds: Int,
        modelDownloadEnabled: Bool
    ) {
        self.preferredBackend = preferredBackend
        self.silenceAutoStopEnabled = silenceAutoStopEnabled
        self.silenceThresholdDBFS = silenceThresholdDBFS
        self.silenceDurationMilliseconds = silenceDurationMilliseconds
        self.minUtteranceMilliseconds = minUtteranceMilliseconds
        self.preRollMilliseconds = preRollMilliseconds
        self.tapThresholdMilliseconds = tapThresholdMilliseconds
        self.hotkeyKeyCode = hotkeyKeyCode
        self.dictationShortcut = dictationShortcut
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
        minUtteranceMilliseconds = try container.decodeIfPresent(Int.self, forKey: .minUtteranceMilliseconds) ?? Self.defaults.minUtteranceMilliseconds
        preRollMilliseconds = try container.decodeIfPresent(Int.self, forKey: .preRollMilliseconds) ?? Self.defaults.preRollMilliseconds
        tapThresholdMilliseconds = try container.decodeIfPresent(Int.self, forKey: .tapThresholdMilliseconds) ?? Self.defaults.tapThresholdMilliseconds
        hotkeyKeyCode = try container.decodeIfPresent(Int.self, forKey: .hotkeyKeyCode) ?? Self.defaults.hotkeyKeyCode
        dictationShortcut = try container.decodeIfPresent(SokkiShortcut.self, forKey: .dictationShortcut)
            ?? SokkiShortcut.legacySingleKey(keyCode: hotkeyKeyCode)
        ambientModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .ambientModeEnabled) ?? Self.defaults.ambientModeEnabled
        ambientToggleShortcut = try container.decodeIfPresent(SokkiShortcut.self, forKey: .ambientToggleShortcut) ?? Self.defaults.ambientToggleShortcut
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
        try container.encode(minUtteranceMilliseconds, forKey: .minUtteranceMilliseconds)
        try container.encode(preRollMilliseconds, forKey: .preRollMilliseconds)
        try container.encode(tapThresholdMilliseconds, forKey: .tapThresholdMilliseconds)
        try container.encode(dictationShortcut.keyCode, forKey: .hotkeyKeyCode)
        try container.encode(dictationShortcut, forKey: .dictationShortcut)
        try container.encode(ambientModeEnabled, forKey: .ambientModeEnabled)
        try container.encode(ambientToggleShortcut, forKey: .ambientToggleShortcut)
        try container.encode(pressEnterAfterPaste, forKey: .pressEnterAfterPaste)
        try container.encode(postPasteEnterDelayMilliseconds, forKey: .postPasteEnterDelayMilliseconds)
        try container.encode(modelDownloadEnabled, forKey: .modelDownloadEnabled)
    }

    public static func load(userDefaults: UserDefaults = .standard) -> SokkiConfig {
        guard let data = userDefaults.data(forKey: defaultsKey),
              var config = try? JSONDecoder().decode(SokkiConfig.self, from: data)
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
        if migrated {
            config.save(userDefaults: userDefaults)
        }
        return config
    }

    public func save(userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
