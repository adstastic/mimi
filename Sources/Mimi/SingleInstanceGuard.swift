import AppKit
import Darwin
import Foundation

final class SingleInstanceGuard {
    let isPrimary: Bool

    private var lockFileDescriptor: Int32 = -1

    init(lockURL: URL = SingleInstanceGuard.defaultLockURL) {
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fileDescriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            isPrimary = true
            return
        }

        if flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
            lockFileDescriptor = fileDescriptor
            isPrimary = true
        } else {
            close(fileDescriptor)
            isPrimary = false
        }
    }

    deinit {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
    }

    @MainActor
    func activateExistingInstance() {
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let appName = AppBrand.name.lowercased()

        let existingApp = NSWorkspace.shared.runningApplications.first { app in
            guard app.processIdentifier != currentProcessID else { return false }
            if let bundleIdentifier, app.bundleIdentifier == bundleIdentifier { return true }
            if app.executableURL?.lastPathComponent.lowercased() == appName { return true }
            return app.localizedName?.lowercased() == appName
        }

        existingApp?.activate(options: [.activateAllWindows])
    }

    private static var defaultLockURL: URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent(AppBrand.name, isDirectory: true)
            .appendingPathComponent("single-instance.lock")
    }
}
