import Foundation

enum AppBrand {
    static let name = "mimi"
    static let legacyName = "Sokki"

    static var errorTitle: String { "\(name) error" }
    static var hotkeyErrorTitle: String { "\(name) hotkey error" }
    static var mlxSidecarMissingMessage: String { "Could not find \(name) MLX sidecar." }
    static var noSpeechErrorDomain: String { name }
}
