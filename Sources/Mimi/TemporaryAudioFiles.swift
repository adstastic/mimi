import Foundation

enum TemporaryAudioFiles {
    private static let directoryNames = ["mimi-", "mimi-owner-"]

    static func removeStaleFiles(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        for name in directoryNames {
            let url = temporaryDirectory
                .appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.removeItem(at: url)
        }
    }
}
