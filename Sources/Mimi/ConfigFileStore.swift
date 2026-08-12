import AppKit
import Darwin
import Foundation

final class MimiConfigFileStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config", isDirectory: true)
        .appendingPathComponent("mimi", isDirectory: true)
        .appendingPathComponent("config.json")

    let fileURL: URL
    private(set) var isWritable = true
    private(set) var errorDescription: String?
    private(set) var didCreateInitialConfig = false

    private let legacyDefaults: UserDefaults
    private var lastKnownData: Data?

    init(
        fileURL: URL = MimiConfigFileStore.defaultURL,
        legacyDefaults: UserDefaults = .standard
    ) {
        self.fileURL = fileURL
        self.legacyDefaults = legacyDefaults
    }

    func loadInitial() -> MimiConfig {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            didCreateInitialConfig = true
            let migrated = MimiConfig.load(userDefaults: legacyDefaults)
            do {
                try write(migrated)
            } catch {
                blockWrites(with: error)
            }
            return migrated
        }

        do {
            let (config, data, needsVocabularyMigration) = try read()
            lastKnownData = data
            config.save(userDefaults: legacyDefaults)
            if needsVocabularyMigration {
                try write(config)
            }
            isWritable = true
            errorDescription = nil
            return config
        } catch {
            blockWrites(with: error)
            return MimiConfig.load(userDefaults: legacyDefaults)
        }
    }

    func reload() throws -> MimiConfig {
        do {
            let (config, data, needsVocabularyMigration) = try read()
            lastKnownData = data
            config.save(userDefaults: legacyDefaults)
            if needsVocabularyMigration {
                try write(config)
            }
            isWritable = true
            errorDescription = nil
            return config
        } catch {
            blockWrites(with: error)
            throw error
        }
    }

    func save(_ config: MimiConfig) throws {
        guard isWritable else {
            throw MimiConfigFileError.writesBlocked(errorDescription ?? "Config file is invalid.")
        }
        do {
            try requireUnchangedFile()
            try write(config)
        } catch {
            blockWrites(with: error)
            throw error
        }
    }

    private func read() throws -> (MimiConfig, Data, Bool) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw MimiConfigFileError.invalid("Config file is missing: \(fileURL.path)")
        }
        let data = try Data(contentsOf: fileURL)
        let needsVocabularyMigration = try rejectUnknownKeys(in: data)
        do {
            let config = try JSONDecoder().decode(MimiConfig.self, from: data)
            try validate(config)
            return (config, data, needsVocabularyMigration)
        } catch let error as MimiConfigFileError {
            throw error
        } catch {
            throw MimiConfigFileError.invalid("Could not decode config: \(error.localizedDescription)")
        }
    }

    private func write(_ config: MimiConfig) throws {
        try validate(config)
        let data = try encodeCanonicalConfig(config)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let temporaryURL = directory.appendingPathComponent(".config-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw MimiConfigFileError.invalid("Could not create secure temporary config file.")
        }
        var preserveTemporaryFile = false
        defer {
            if !preserveTemporaryFile {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        try replaceAtomically(with: temporaryURL, preserveTemporaryFile: &preserveTemporaryFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        lastKnownData = data
        config.save(userDefaults: legacyDefaults)
        isWritable = true
        errorDescription = nil
    }

    private func encodeCanonicalConfig(_ config: MimiConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(CanonicalMimiConfig(config))
        guard var json = String(data: data, encoding: .utf8),
              let marker = json.range(of: "\"vocabulary\" : ["),
              let closing = json.range(of: "\n  ],", range: marker.upperBound ..< json.endIndex) else {
            throw MimiConfigFileError.invalid("Could not format vocabulary config.")
        }
        let arrayStart = json.index(before: marker.upperBound)
        let arrayEnd = json.index(closing.lowerBound, offsetBy: 3)

        let scalarEncoder = JSONEncoder()
        scalarEncoder.outputFormatting = [.withoutEscapingSlashes]
        let lines = try config.vocabulary.map { entry in
            let sources = try entry.from.map {
                try String(decoding: scalarEncoder.encode($0), as: UTF8.self)
            }.joined(separator: ", ")
            let target = try String(decoding: scalarEncoder.encode(entry.to), as: UTF8.self)
            return "    { \"from\" : [\(sources)], \"to\" : \(target) }"
        }
        let compactArray = lines.isEmpty ? "[]" : "[\n\(lines.joined(separator: ",\n"))\n  ]"
        json.replaceSubrange(arrayStart ... arrayEnd, with: compactArray)
        return Data(json.utf8)
    }

    private func replaceAtomically(
        with temporaryURL: URL,
        preserveTemporaryFile: inout Bool
    ) throws {
        guard let lastKnownData else {
            guard Darwin.renamex_np(temporaryURL.path, fileURL.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw MimiConfigFileError.externalChange }
                throw MimiConfigFileError.invalid(
                    "Could not create config atomically: \(String(cString: strerror(errno)))"
                )
            }
            return
        }

        guard Darwin.renamex_np(temporaryURL.path, fileURL.path, UInt32(RENAME_SWAP)) == 0 else {
            if errno == ENOENT { throw MimiConfigFileError.externalChange }
            throw MimiConfigFileError.invalid(
                "Could not replace config atomically: \(String(cString: strerror(errno)))"
            )
        }
        do {
            guard try Data(contentsOf: temporaryURL) == lastKnownData else {
                throw MimiConfigFileError.externalChange
            }
        } catch {
            guard Darwin.renamex_np(temporaryURL.path, fileURL.path, UInt32(RENAME_SWAP)) == 0 else {
                preserveTemporaryFile = true
                let recoveryURL = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("config.recovery-\(UUID().uuidString).json")
                let preservedURL: URL
                if Darwin.rename(temporaryURL.path, recoveryURL.path) == 0 {
                    preservedURL = recoveryURL
                } else {
                    preservedURL = temporaryURL
                }
                throw MimiConfigFileError.invalid(
                    "Config changed during save and could not be restored. Original preserved at \(preservedURL.path)."
                )
            }
            throw error
        }
    }

    private func requireUnchangedFile() throws {
        guard let lastKnownData else {
            guard !FileManager.default.fileExists(atPath: fileURL.path) else {
                throw MimiConfigFileError.externalChange
            }
            return
        }
        guard let currentData = try? Data(contentsOf: fileURL), currentData == lastKnownData else {
            throw MimiConfigFileError.externalChange
        }
    }

    private func blockWrites(with error: Error) {
        isWritable = false
        errorDescription = error.localizedDescription
    }

    private func rejectUnknownKeys(in data: Data) throws -> Bool {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MimiConfigFileError.invalid("Config root must be a JSON object.")
        }
        let hasVocabulary = object["vocabulary"] != nil
        let hasLegacyVocabulary = object["vocabularyEntries"] != nil
        guard !hasVocabulary || !hasLegacyVocabulary else {
            throw MimiConfigFileError.invalid("Use vocabulary, not both vocabulary and vocabularyEntries.")
        }
        try rejectUnknownKeys(
            in: object,
            allowed: CanonicalMimiConfig.keys.union(["vocabularyEntries"]),
            path: "config"
        )
        try rejectUnknownKeys(
            in: object["dictationShortcut"],
            allowed: ["keyCode", "modifierFlagsRaw"],
            path: "dictationShortcut"
        )
        try rejectUnknownKeys(
            in: object["ambientToggleShortcut"],
            allowed: ["keyCode", "modifierFlagsRaw"],
            path: "ambientToggleShortcut"
        )
        try rejectUnknownKeys(
            in: object["correctionShortcut"],
            allowed: ["keyCode", "modifierFlagsRaw"],
            path: "correctionShortcut"
        )
        let pasteKeys: Set<String> = [
            "prePasteKeystroke", "postPasteKeystroke",
            "prePasteDelayMilliseconds", "postPasteDelayMilliseconds"
        ]
        try rejectUnknownPasteKeys(in: object["dictationPasteSettings"], allowed: pasteKeys, path: "dictationPasteSettings")
        try rejectUnknownPasteKeys(in: object["ambientPasteSettings"], allowed: pasteKeys, path: "ambientPasteSettings")
        try rejectUnknownKeys(
            in: object["pastePresetShortcut"],
            allowed: ["keyCode", "modifierFlagsRaw"],
            path: "pastePresetShortcut"
        )
        if let presets = object["pastePresets"] as? [Any] {
            for (index, preset) in presets.enumerated() {
                let path = "pastePresets[\(index)]"
                try rejectUnknownKeys(in: preset, allowed: ["name", "paste"], path: path)
                try rejectUnknownPasteKeys(
                    in: (preset as? [String: Any])?["paste"],
                    allowed: pasteKeys,
                    path: "\(path).paste"
                )
            }
        }
        if let entries = object["vocabulary"] as? [Any] {
            for (index, entry) in entries.enumerated() {
                try rejectUnknownKeys(
                    in: entry,
                    allowed: ["from", "to"],
                    path: "vocabulary[\(index)]"
                )
            }
        }
        if let entries = object["vocabularyEntries"] as? [Any] {
            for (index, entry) in entries.enumerated() {
                try rejectUnknownKeys(
                    in: entry,
                    allowed: ["id", "writtenForm", "spokenAliases", "isEnabled"],
                    path: "vocabularyEntries[\(index)]"
                )
            }
        }
        if let rawMode = object["silenceDetectionMode"] as? String,
           SilenceDetectionMode(rawValue: rawMode) == nil {
            throw MimiConfigFileError.invalid("Invalid silenceDetectionMode: \(rawMode)")
        }
        return hasLegacyVocabulary
    }

    private func rejectUnknownPasteKeys(in value: Any?, allowed: Set<String>, path: String) throws {
        try rejectUnknownKeys(in: value, allowed: allowed, path: path)
        guard let paste = value as? [String: Any] else { return }
        let shortcutKeys: Set<String> = ["keyCode", "modifierFlagsRaw"]
        try rejectUnknownKeys(
            in: paste["prePasteKeystroke"],
            allowed: shortcutKeys,
            path: "\(path).prePasteKeystroke"
        )
        try rejectUnknownKeys(
            in: paste["postPasteKeystroke"],
            allowed: shortcutKeys,
            path: "\(path).postPasteKeystroke"
        )
    }

    private func rejectUnknownKeys(in value: Any?, allowed: Set<String>, path: String) throws {
        guard let value, let object = value as? [String: Any] else { return }
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw MimiConfigFileError.invalid(
                "Unknown config key at \(path): \(unknown.sorted().joined(separator: ", "))"
            )
        }
    }

    private func validate(_ config: MimiConfig) throws {
        try validateShortcut(config.dictationShortcut, name: "dictationShortcut")
        try validateShortcut(config.ambientToggleShortcut, name: "ambientToggleShortcut")
        try validateShortcut(config.correctionShortcut, name: "correctionShortcut")
        try validateShortcut(config.dictationPasteSettings.prePasteKeystroke, name: "dictationPasteSettings.prePasteKeystroke")
        try validateShortcut(config.dictationPasteSettings.postPasteKeystroke, name: "dictationPasteSettings.postPasteKeystroke")
        try validateShortcut(config.ambientPasteSettings.prePasteKeystroke, name: "ambientPasteSettings.prePasteKeystroke")
        try validateShortcut(config.ambientPasteSettings.postPasteKeystroke, name: "ambientPasteSettings.postPasteKeystroke")
        try require((-65 ... -15).contains(config.silenceThresholdDBFS), "silenceThresholdDBFS must be between -65 and -15.")
        try require((0 ... 3_000).contains(config.silenceDurationMilliseconds), "silenceDurationMilliseconds must be between 0 and 3000.")
        try require((200 ... 1_000).contains(config.minUtteranceMilliseconds), "minUtteranceMilliseconds must be between 200 and 1000.")
        try require((0 ... 1_500).contains(config.preRollMilliseconds), "preRollMilliseconds must be between 0 and 1500.")
        try require((120 ... 500).contains(config.tapThresholdMilliseconds), "tapThresholdMilliseconds must be between 120 and 500.")
        try require((0 ... 5_000).contains(config.dictationPasteSettings.prePasteDelayMilliseconds), "Dictation pre-paste delay must be between 0 and 5000.")
        try require((0 ... 5_000).contains(config.dictationPasteSettings.postPasteDelayMilliseconds), "Dictation post-paste delay must be between 0 and 5000.")
        try require((0 ... 5_000).contains(config.ambientPasteSettings.prePasteDelayMilliseconds), "Ambient pre-paste delay must be between 0 and 5000.")
        try require((0 ... 5_000).contains(config.ambientPasteSettings.postPasteDelayMilliseconds), "Ambient post-paste delay must be between 0 and 5000.")
        try validateShortcut(config.pastePresetShortcut, name: "pastePresetShortcut")
        var presetNames = Set<String>()
        for preset in config.pastePresets {
            let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
            try require(!name.isEmpty, "pastePresets names must not be empty.")
            try require(name != PastePreset.manualName, "pastePresets cannot use the reserved name \(PastePreset.manualName).")
            try require(presetNames.insert(name).inserted, "pastePresets names must be unique: \(name)")
            try validateShortcut(preset.paste.prePasteKeystroke, name: "pastePresets[\(name)].prePasteKeystroke")
            try validateShortcut(preset.paste.postPasteKeystroke, name: "pastePresets[\(name)].postPasteKeystroke")
            try require((0 ... 5_000).contains(preset.paste.prePasteDelayMilliseconds), "Preset \(name) pre-paste delay must be between 0 and 5000.")
            try require((0 ... 5_000).contains(preset.paste.postPasteDelayMilliseconds), "Preset \(name) post-paste delay must be between 0 and 5000.")
        }
        if let activeName = config.activePastePresetName {
            try require(presetNames.contains(activeName), "activePastePresetName has no matching preset: \(activeName)")
        }
        try require((0.45 ... 0.95).contains(config.voiceprintThreshold), "voiceprintThreshold must be between 0.45 and 0.95.")
        try require(
            config.preferredBackend.capabilities.supportsSilenceDetectionMode(config.silenceDetectionMode),
            "silenceDetectionMode is unsupported by preferredBackend."
        )
        try require(
            !config.ambientModeEnabled || config.preferredBackend.capabilities.supportsAmbient,
            "ambientModeEnabled is unsupported by preferredBackend."
        )
        if let error = VocabularyValidator.validate(config.vocabulary) {
            throw MimiConfigFileError.invalid(error.localizedDescription)
        }
    }

    private func validateShortcut(_ shortcut: MimiShortcut?, name: String) throws {
        guard let shortcut else { return }
        try require((0 ... 127).contains(shortcut.keyCode), "\(name).keyCode must be between 0 and 127.")
        try require(
            shortcut.modifierFlags.rawValue == shortcut.modifierFlagsRaw,
            "\(name).modifierFlagsRaw contains unsupported flags."
        )
    }

    private func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw MimiConfigFileError.invalid(message) }
    }
}

enum MimiConfigFileError: LocalizedError {
    case invalid(String)
    case writesBlocked(String)
    case externalChange

    var errorDescription: String? {
        switch self {
        case .invalid(let message):
            message
        case .writesBlocked(let message):
            "Config writes blocked: \(message)"
        case .externalChange:
            "Config file changed outside Mimi. Reload Config before saving."
        }
    }
}

private struct CanonicalMimiConfig: Encodable {
    static let keys: Set<String> = Set(CodingKeys.allCases.map(\.rawValue))

    let config: MimiConfig

    init(_ config: MimiConfig) {
        self.config = config
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case preferredBackend
        case silenceAutoStopEnabled
        case silenceThresholdDBFS
        case silenceDurationMilliseconds
        case silenceDetectionMode
        case minUtteranceMilliseconds
        case preRollMilliseconds
        case tapThresholdMilliseconds
        case dictationShortcut
        case inputDeviceID
        case ambientModeEnabled
        case ambientToggleShortcut
        case correctionShortcut
        case dictationPasteSettings
        case ambientPasteSettings
        case pastePresets
        case activePastePresetName
        case pastePresetShortcut
        case showLiveTranscript
        case fillerCleanupEnabled
        case vocabulary
        case voiceprintEnabled
        case voiceprintThreshold
        case modelDownloadEnabled
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(config.preferredBackend, forKey: .preferredBackend)
        try container.encode(config.silenceAutoStopEnabled, forKey: .silenceAutoStopEnabled)
        try container.encode(config.silenceThresholdDBFS, forKey: .silenceThresholdDBFS)
        try container.encode(config.silenceDurationMilliseconds, forKey: .silenceDurationMilliseconds)
        try container.encode(config.silenceDetectionMode, forKey: .silenceDetectionMode)
        try container.encode(config.minUtteranceMilliseconds, forKey: .minUtteranceMilliseconds)
        try container.encode(config.preRollMilliseconds, forKey: .preRollMilliseconds)
        try container.encode(config.tapThresholdMilliseconds, forKey: .tapThresholdMilliseconds)
        try container.encode(config.dictationShortcut, forKey: .dictationShortcut)
        try container.encodeIfPresent(config.inputDeviceID, forKey: .inputDeviceID)
        try container.encode(config.ambientModeEnabled, forKey: .ambientModeEnabled)
        try container.encode(config.ambientToggleShortcut, forKey: .ambientToggleShortcut)
        try container.encode(config.correctionShortcut, forKey: .correctionShortcut)
        try container.encode(config.dictationPasteSettings, forKey: .dictationPasteSettings)
        try container.encode(config.ambientPasteSettings, forKey: .ambientPasteSettings)
        try container.encode(config.pastePresets, forKey: .pastePresets)
        try container.encodeIfPresent(config.activePastePresetName, forKey: .activePastePresetName)
        try container.encode(config.pastePresetShortcut, forKey: .pastePresetShortcut)
        try container.encode(config.showLiveTranscript, forKey: .showLiveTranscript)
        try container.encode(config.fillerCleanupEnabled, forKey: .fillerCleanupEnabled)
        try container.encode(config.vocabulary, forKey: .vocabulary)
        try container.encode(config.voiceprintEnabled, forKey: .voiceprintEnabled)
        try container.encode(config.voiceprintThreshold, forKey: .voiceprintThreshold)
        try container.encode(config.modelDownloadEnabled, forKey: .modelDownloadEnabled)
    }
}
