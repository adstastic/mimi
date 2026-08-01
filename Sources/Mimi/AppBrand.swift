import AppKit
import Foundation

enum AppBrand {
    static let name = "mimi"

    static var errorTitle: String { "\(name) error" }
    static var hotkeyErrorTitle: String { "\(name) hotkey error" }
    static var mlxSidecarMissingMessage: String { "Could not find \(name) MLX sidecar." }
    static var noSpeechErrorDomain: String { name }

    static var logoImage: NSImage? {
        imageResource(named: "AppLogo.png")
    }

    static var iconImage: NSImage? {
        imageResource(named: "AppIcon.png") ?? logoImage
    }

    static var menuBarImage: NSImage? {
        guard let source = imageResource(named: "MenuBarIcon.png") ?? logoImage,
              let image = source.copy() as? NSImage else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 11, height: 15)
        return image
    }

    private static func imageResource(named filename: String) -> NSImage? {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(filename),
           let image = NSImage(contentsOf: url) {
            return image
        }
        let repoURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent(filename)
        return NSImage(contentsOf: repoURL)
    }
}
