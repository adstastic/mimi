import Foundation

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

    public var preferredBackend: ASRBackend
    public var silenceAutoStopEnabled: Bool
    public var silenceThresholdDBFS: Double
    public var silenceDurationMilliseconds: Int
    public var minUtteranceMilliseconds: Int
    public var preRollMilliseconds: Int
    public var tapThresholdMilliseconds: Int
    public var hotkeyKeyCode: Int
    public var ambientModeEnabled: Bool
    public var pressEnterAfterPaste: Bool
    public var postPasteEnterDelayMilliseconds: Int
    public var telemetryEnabled: Bool
    public var cloudTranscriptionEnabled: Bool
    public var modelDownloadEnabled: Bool

    public static let defaults = SokkiConfig(
        preferredBackend: .mlxParakeetV2,
        silenceAutoStopEnabled: true,
        silenceThresholdDBFS: -50,
        silenceDurationMilliseconds: 2_000,
        minUtteranceMilliseconds: 350,
        preRollMilliseconds: 700,
        tapThresholdMilliseconds: 220,
        hotkeyKeyCode: 54, // Right Command on Apple keyboards.
        ambientModeEnabled: false,
        pressEnterAfterPaste: true,
        postPasteEnterDelayMilliseconds: 150,
        telemetryEnabled: false,
        cloudTranscriptionEnabled: false,
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
        ambientModeEnabled: Bool,
        pressEnterAfterPaste: Bool,
        postPasteEnterDelayMilliseconds: Int,
        telemetryEnabled: Bool,
        cloudTranscriptionEnabled: Bool,
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
        self.ambientModeEnabled = ambientModeEnabled
        self.pressEnterAfterPaste = pressEnterAfterPaste
        self.postPasteEnterDelayMilliseconds = postPasteEnterDelayMilliseconds
        self.telemetryEnabled = telemetryEnabled
        self.cloudTranscriptionEnabled = cloudTranscriptionEnabled
        self.modelDownloadEnabled = modelDownloadEnabled
    }

    public var isLocalOnlyNoTelemetry: Bool {
        telemetryEnabled == false && cloudTranscriptionEnabled == false
    }

    public static func load(userDefaults: UserDefaults = .standard) -> SokkiConfig {
        guard let data = userDefaults.data(forKey: defaultsKey),
              var config = try? JSONDecoder().decode(SokkiConfig.self, from: data)
        else { return .defaults }
        if config.silenceThresholdDBFS == -38 {
            config.silenceThresholdDBFS = Self.defaults.silenceThresholdDBFS
        }
        return config
    }

    public func save(userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
