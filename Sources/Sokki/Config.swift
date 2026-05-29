import Foundation

public enum ASRBackend: String, Codable, Equatable, Sendable {
    case mlxParakeetV2

    var displayName: String {
        switch self {
        case .mlxParakeetV2:
            "MLX Parakeet v2"
        }
    }
}

public enum AutoEnterMode: String, Codable, Equatable, Sendable {
    case off
    case always
}

public struct SokkiConfig: Codable, Equatable, Sendable {
    private static let defaultsKey = "SokkiConfig.v1"

    public var preferredBackend: ASRBackend
    public var silenceThresholdDBFS: Double
    public var silenceDurationMilliseconds: Int
    public var minUtteranceMilliseconds: Int
    public var preRollMilliseconds: Int
    public var tapThresholdMilliseconds: Int
    public var hotkeyKeyCode: Int
    public var ambientModeEnabled: Bool
    public var autoEnterMode: AutoEnterMode
    public var postPasteEnterDelayMilliseconds: Int
    public var telemetryEnabled: Bool
    public var cloudTranscriptionEnabled: Bool
    public var modelDownloadEnabled: Bool

    public static let defaults = SokkiConfig(
        preferredBackend: .mlxParakeetV2,
        silenceThresholdDBFS: -38,
        silenceDurationMilliseconds: 1_000,
        minUtteranceMilliseconds: 350,
        preRollMilliseconds: 700,
        tapThresholdMilliseconds: 220,
        hotkeyKeyCode: 61, // Right Option on Apple keyboards.
        ambientModeEnabled: false,
        autoEnterMode: .off,
        postPasteEnterDelayMilliseconds: 150,
        telemetryEnabled: false,
        cloudTranscriptionEnabled: false,
        modelDownloadEnabled: true
    )

    public init(
        preferredBackend: ASRBackend,
        silenceThresholdDBFS: Double,
        silenceDurationMilliseconds: Int,
        minUtteranceMilliseconds: Int,
        preRollMilliseconds: Int,
        tapThresholdMilliseconds: Int,
        hotkeyKeyCode: Int,
        ambientModeEnabled: Bool,
        autoEnterMode: AutoEnterMode,
        postPasteEnterDelayMilliseconds: Int,
        telemetryEnabled: Bool,
        cloudTranscriptionEnabled: Bool,
        modelDownloadEnabled: Bool
    ) {
        self.preferredBackend = preferredBackend
        self.silenceThresholdDBFS = silenceThresholdDBFS
        self.silenceDurationMilliseconds = silenceDurationMilliseconds
        self.minUtteranceMilliseconds = minUtteranceMilliseconds
        self.preRollMilliseconds = preRollMilliseconds
        self.tapThresholdMilliseconds = tapThresholdMilliseconds
        self.hotkeyKeyCode = hotkeyKeyCode
        self.ambientModeEnabled = ambientModeEnabled
        self.autoEnterMode = autoEnterMode
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
              let config = try? JSONDecoder().decode(SokkiConfig.self, from: data)
        else { return .defaults }
        return config
    }

    public func save(userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        userDefaults.set(data, forKey: Self.defaultsKey)
    }
}
