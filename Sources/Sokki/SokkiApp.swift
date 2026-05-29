import AppKit
import SwiftUI

@main
struct SokkiApp: App {
    @Environment(\.openWindow) private var openWindow

    private let config = SokkiConfig.defaults

    var body: some Scene {
        MenuBarExtra("Sokki", systemImage: "mic") {
            Button("Settings...") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: SettingsWindow.identifier)
            }

            Button("Retry Last Insert") {}
                .disabled(true)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)

        Window("Settings", id: SettingsWindow.identifier) {
            SettingsView(config: config)
        }
        .defaultSize(width: 420, height: 260)
    }
}

private enum SettingsWindow {
    static let identifier = "settings"
}
