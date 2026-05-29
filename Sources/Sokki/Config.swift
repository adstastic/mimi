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

public struct SokkiConfig: Codable, Equatable, Sendable {
    public var preferredBackend: ASRBackend
    public var silenceThresholdDBFS: Double
    public var silenceDurationMilliseconds: Int
    public var minUtteranceMilliseconds: Int
    public var preRollMilliseconds: Int
    public var ambientModeEnabled: Bool
    public var telemetryEnabled: Bool
    public var allowsNetworkAccess: Bool

    public static let defaults = SokkiConfig(
        preferredBackend: .mlxParakeetV2,
        silenceThresholdDBFS: -38,
        silenceDurationMilliseconds: 1_000,
        minUtteranceMilliseconds: 350,
        preRollMilliseconds: 700,
        ambientModeEnabled: false,
        telemetryEnabled: false,
        allowsNetworkAccess: false
    )

    public init(
        preferredBackend: ASRBackend,
        silenceThresholdDBFS: Double,
        silenceDurationMilliseconds: Int,
        minUtteranceMilliseconds: Int,
        preRollMilliseconds: Int,
        ambientModeEnabled: Bool,
        telemetryEnabled: Bool,
        allowsNetworkAccess: Bool
    ) {
        self.preferredBackend = preferredBackend
        self.silenceThresholdDBFS = silenceThresholdDBFS
        self.silenceDurationMilliseconds = silenceDurationMilliseconds
        self.minUtteranceMilliseconds = minUtteranceMilliseconds
        self.preRollMilliseconds = preRollMilliseconds
        self.ambientModeEnabled = ambientModeEnabled
        self.telemetryEnabled = telemetryEnabled
        self.allowsNetworkAccess = allowsNetworkAccess
    }

    public var isLocalOnlyNoTelemetry: Bool {
        telemetryEnabled == false && allowsNetworkAccess == false
    }
}
