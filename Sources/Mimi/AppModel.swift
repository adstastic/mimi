import AppKit
import Combine
import Foundation
import MimiSpeech

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var statusText = "Starting…"
    @Published private(set) var lastTranscript: String?
    @Published private(set) var permissionStatus = PermissionStatus.current()
    @Published private(set) var inputDevices = AudioInputDevice.available()
    @Published private(set) var voiceprintStatus = "No voice enrolled"
    @Published private(set) var voiceprintProfileExists = false
    @Published private(set) var voiceprintBusy = false
    @Published private(set) var configErrorText: String?
    @Published private(set) var correctionRequestID = 0
    @Published var config: MimiConfig {
        didSet {
            let normalized = config.normalizedForBackend()
            if normalized != config {
                config = normalized
            }
            if !isApplyingConfigReload {
                do {
                    try configStore.save(config)
                    configErrorText = nil
                } catch {
                    configErrorText = error.localizedDescription
                    applyStatus("Config error: \(error.localizedDescription)")
                }
            }
            if oldValue.preferredBackend != config.preferredBackend {
                dictationController.prepareASR()
                if config.ambientModeEnabled {
                    scheduleAmbientModeUpdate()
                }
            }
            if oldValue.ambientModeEnabled != config.ambientModeEnabled {
                scheduleAmbientModeUpdate()
            }
            if oldValue.inputDeviceID != config.inputDeviceID || oldValue.silenceDetectionMode != config.silenceDetectionMode {
                scheduleAmbientModeUpdate()
            }
            if !shortcutRecording,
               oldValue.dictationShortcut != config.dictationShortcut
                || oldValue.dictationToggleShortcut != config.dictationToggleShortcut
                || oldValue.ambientToggleShortcut != config.ambientToggleShortcut
                || oldValue.correctionShortcut != config.correctionShortcut
                || oldValue.pastePresetShortcut != config.pastePresetShortcut {
                restartHotkeyMonitor()
            }
        }
    }

    let history: HistoryStore
    let shouldShowSettingsOnLaunch: Bool

    var lastDictation: TranscriptEntry? { history.latest }

    private let configStore: MimiConfigFileStore
    private let audioCapture = AudioCapture()
    private let textInserter = TextInserter()
    private let voiceprintService = VoiceprintEmbeddingService()
    private var voiceprintVerifier: FileVoiceprintVerifier!
    private let overlay = OverlayWindowController()
    private var asrService: ASRService!
    private var dictationController: DictationController!
    private var hotkeyMonitor: HotkeyMonitor!
    private var wakeCancellable: AnyCancellable?
    private var terminationCancellable: AnyCancellable?
    private var inputDeviceTask: Task<Void, Never>?
    private var ambientModeUpdateTask: Task<Void, Never>?
    private var audioPreparationTask: Task<Void, Never>?
    private var voiceprintTemporaryAudioURL: URL?
    private var lastDefaultInputDeviceID = AudioInputDevice.defaultInputDeviceUID()
    private var lastDefaultOutputDeviceID = AudioInputDevice.defaultOutputDeviceUID()
    private var started = false
    private var shortcutRecording = false
    private var isApplyingConfigReload = false

    init() {
        TemporaryAudioFiles.removeStaleFiles()
        let configStore = MimiConfigFileStore()
        self.configStore = configStore
        history = HistoryStore(audioStorageURL: HistoryStore.productionAudioStorageURL)
        let loadedInputDevices = AudioInputDevice.available()
        var loadedConfig = configStore.loadInitial()
        shouldShowSettingsOnLaunch = configStore.didCreateInitialConfig
        let validInputDeviceID = AudioInputDevice.validSelection(loadedConfig.inputDeviceID, in: loadedInputDevices)
        if validInputDeviceID != loadedConfig.inputDeviceID {
            loadedConfig.inputDeviceID = validInputDeviceID
            try? configStore.save(loadedConfig)
        }
        config = loadedConfig
        configErrorText = configStore.errorDescription
        inputDevices = loadedInputDevices
        refreshVoiceprintState()

        asrService = ASRService(onStatus: { [weak self] status in
            Task { @MainActor in
                self?.applyStatus(status)
            }
        })
        voiceprintVerifier = FileVoiceprintVerifier(service: voiceprintService)
        dictationController = DictationController(
            configProvider: { [weak self] in self?.config ?? .defaults },
            audioCapture: audioCapture,
            asrService: asrService,
            voiceprintVerifier: voiceprintVerifier,
            textInserter: textInserter,
            history: history,
            overlay: overlay,
            onStatus: { [weak self] status in self?.applyStatus(status) },
            onTranscript: { [weak self] transcript in self?.lastTranscript = transcript },
            onPartialTranscript: { _ in }
        )
        hotkeyMonitor = HotkeyMonitor(
            dictationShortcut: config.dictationShortcut,
            dictationToggleShortcut: config.dictationToggleShortcut,
            ambientToggleShortcut: config.ambientToggleShortcut,
            correctionShortcut: config.correctionShortcut,
            pastePresetShortcut: config.pastePresetShortcut,
            onDictationDown: { [weak self] in self?.dictationController.hotkeyDown() },
            onDictationUp: { [weak self] in self?.dictationController.hotkeyUp() },
            onDictationToggle: { [weak self] in self?.dictationController.toggleDictation() },
            onAmbientToggle: { [weak self] in self?.toggleAmbientModeFromShortcut() },
            onCorrection: { [weak self] in self?.requestLastTranscriptCorrection() },
            onPastePresetCycle: { [weak self] in self?.cyclePastePresetFromShortcut() },
            onCancel: { [weak self] in self?.dictationController.cancelRecording() },
            recordingIsActive: { [weak self] in self?.dictationController.isRecording ?? false }
        )
        terminationCancellable = NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cleanupForTermination()
                }
            }

        Task { await start() }
    }

    func start() async {
        guard !started else { return }
        started = true
        refreshPermissions()

        dictationController.prepareASR()
        wakeCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleSystemWake()
                }
            }
        dictationController.updateAmbientMode()
        startInputDeviceWatcher()
        scheduleAudioPreparation()
    }

    func refreshInputDevices() {
        inputDevices = AudioInputDevice.available()
        lastDefaultInputDeviceID = AudioInputDevice.defaultInputDeviceUID()
        lastDefaultOutputDeviceID = AudioInputDevice.defaultOutputDeviceUID()
        let resetMissingDevice = resetMissingSelectedInputDevice()
        if config.ambientModeEnabled, !resetMissingDevice {
            scheduleAmbientModeUpdate()
        }
    }

    private func handleSystemWake() {
        if config.ambientModeEnabled {
            dictationController.updateAmbientMode()
        } else {
            scheduleAudioPreparation()
        }
    }

    private func scheduleAudioPreparation() {
        guard permissionStatus.microphone,
              audioPreparationTask == nil,
              !voiceprintBusy,
              !config.ambientModeEnabled else { return }
        audioPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.dictationController.prepareAudio()
            self.audioPreparationTask = nil
        }
    }

    private func startInputDeviceWatcher() {
        inputDeviceTask?.cancel()
        inputDeviceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    guard let self else { return }
                    let devices = AudioInputDevice.available()
                    let defaultInputDeviceID = AudioInputDevice.defaultInputDeviceUID()
                    let defaultOutputDeviceID = AudioInputDevice.defaultOutputDeviceUID()
                    let devicesChanged = devices != self.inputDevices
                    let defaultInputChanged = defaultInputDeviceID != self.lastDefaultInputDeviceID
                    let defaultOutputChanged = defaultOutputDeviceID != self.lastDefaultOutputDeviceID
                    if devicesChanged {
                        self.inputDevices = devices
                    }
                    if defaultInputChanged {
                        self.lastDefaultInputDeviceID = defaultInputDeviceID
                    }
                    if defaultOutputChanged {
                        self.lastDefaultOutputDeviceID = defaultOutputDeviceID
                    }
                    let resetMissingDevice = self.resetMissingSelectedInputDevice()
                    if (devicesChanged || defaultInputChanged || defaultOutputChanged),
                       self.config.ambientModeEnabled,
                       !resetMissingDevice {
                        self.scheduleAmbientModeUpdate()
                    }
                }
            }
        }
    }

    private func applyStatus(_ status: String) {
        statusText = status
    }

    @discardableResult
    private func resetMissingSelectedInputDevice() -> Bool {
        let validInputDeviceID = AudioInputDevice.validSelection(config.inputDeviceID, in: inputDevices)
        guard validInputDeviceID != config.inputDeviceID else { return false }
        config.inputDeviceID = validInputDeviceID
        return true
    }

    private func scheduleAmbientModeUpdate() {
        ambientModeUpdateTask?.cancel()
        ambientModeUpdateTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.dictationController.updateAmbientMode()
        }
    }

    private func restartHotkeyMonitor() {
        hotkeyMonitor.update(
            dictationShortcut: config.dictationShortcut,
            dictationToggleShortcut: config.dictationToggleShortcut,
            ambientToggleShortcut: config.ambientToggleShortcut,
            correctionShortcut: config.correctionShortcut,
            pastePresetShortcut: config.pastePresetShortcut
        )
        guard started else { return }
        hotkeyMonitor.stop()
        startHotkeyMonitor()
    }

    private func startHotkeyMonitor() {
        guard !shortcutRecording, !hotkeyMonitor.isRunning else { return }
        guard permissionStatus.globalShortcutsGranted else {
            applyStatus("Permissions required")
            return
        }
        do {
            try hotkeyMonitor.start()
        } catch {
            applyStatus("Hotkey error: \(error.localizedDescription)")
            overlay.show(AppBrand.hotkeyErrorTitle, detail: error.localizedDescription)
        }
    }

    private func cyclePastePresetFromShortcut() {
        config.cyclePastePreset()
        overlay.show(
            "Paste: \(config.activePastePresetLabel)",
            detail: config.pasteSettings(isAmbient: config.ambientModeEnabled).keystrokeSummary
        )
        overlay.hide(after: 1_200)
    }

    private func toggleAmbientModeFromShortcut() {
        guard config.preferredBackend.capabilities.supportsAmbient else { return }
        config.ambientModeEnabled.toggle()
        let enabled = config.ambientModeEnabled
        overlay.show(enabled ? "Ambient mode on" : "Ambient mode off")
        overlay.hide(after: 900)
    }

    func setShortcutRecording(_ recording: Bool) {
        shortcutRecording = recording
        if recording {
            hotkeyMonitor.stop()
        } else if started {
            restartHotkeyMonitor()
        }
    }

    func refreshPermissions() {
        permissionStatus = PermissionStatus.current()
        if started {
            startHotkeyMonitor()
        }
    }

    func copyLastTranscript() {
        dictationController.copyLastTranscript()
    }

    func requestLastTranscriptCorrection() {
        guard history.latest != nil else {
            overlay.show("Nothing to correct", detail: "Dictate something first.")
            overlay.hide(after: 1_200)
            return
        }
        correctionRequestID &+= 1
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func consumeCorrectionRequest(_ requestID: Int) {
        if correctionRequestID == requestID {
            correctionRequestID = 0
        }
    }

    func correctLastTranscript(
        id: UUID,
        text: String,
        corrections: [VocabularyCorrectionSuggestion]
    ) -> Result<Void, Error> {
        guard history.latest?.id == id else {
            return .failure(MimiConfigFileError.invalid("Last dictation changed. Open Correct again."))
        }

        do {
            if !corrections.isEmpty {
                var updatedConfig = config
                updatedConfig.vocabulary = try VocabularyEntryUpdater.addingCorrections(
                    corrections,
                    to: config.vocabulary
                )
                try configStore.save(updatedConfig)
                isApplyingConfigReload = true
                config = updatedConfig
                isApplyingConfigReload = false
                configErrorText = nil
            }
            guard dictationController.correctLastTranscript(id: id, text: text) else {
                return .failure(MimiConfigFileError.invalid("Last dictation changed. Open Correct again."))
            }
            return .success(())
        } catch {
            isApplyingConfigReload = false
            configErrorText = error.localizedDescription
            applyStatus("Config error: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    func openConfigFile() {
        NSWorkspace.shared.open(configStore.fileURL)
    }

    func reloadConfig() {
        do {
            let loaded = try configStore.reload()
            isApplyingConfigReload = true
            config = loaded
            isApplyingConfigReload = false
            configErrorText = nil
            applyStatus("Config reloaded")
            overlay.show("Config reloaded", detail: configStore.fileURL.path)
            overlay.hide(after: 1_200)
        } catch {
            isApplyingConfigReload = false
            configErrorText = error.localizedDescription
            applyStatus("Config error: \(error.localizedDescription)")
            overlay.show("Config error", detail: error.localizedDescription)
        }
    }

    func quit() {
        cleanupForTermination()
        NSApplication.shared.terminate(nil)
    }

    private func cleanupForTermination() {
        inputDeviceTask?.cancel()
        ambientModeUpdateTask?.cancel()
        audioPreparationTask?.cancel()
        hotkeyMonitor.stop()
        dictationController.shutdown()
        removeVoiceprintTemporaryAudio()
        history.clear()
    }

    private func removeVoiceprintTemporaryAudio() {
        guard let voiceprintTemporaryAudioURL else { return }
        try? FileManager.default.removeItem(at: voiceprintTemporaryAudioURL)
        self.voiceprintTemporaryAudioURL = nil
    }

    func enrollVoiceprint() {
        Task { await runVoiceprintEnrollment() }
    }

    func verifyVoiceprint() {
        Task { await runVoiceprintVerification() }
    }

    func resetVoiceprint() {
        do {
            try FileManager.default.removeItem(at: VoiceprintPrototype.defaultProfileURL)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            voiceprintStatus = "Reset error: \(error.localizedDescription)"
            return
        }
        refreshVoiceprintState()
        overlay.show("Voiceprint reset")
        overlay.hide(after: 900)
    }

    func cancelRecording() {
        dictationController.cancelRecording()
    }

    private func runVoiceprintEnrollment() async {
        guard await beginVoiceprintAction() else { return }
        defer { voiceprintBusy = false }

        do {
            applyStatus("Voice enroll — read prompt")
            overlay.show("Voice enroll", detail: "Read the My Voice phrase for 8 seconds")
            let audioURL = try await recordVoiceprintClip(seconds: 8)
            voiceprintTemporaryAudioURL = audioURL
            defer { removeVoiceprintTemporaryAudio() }
            applyStatus("Building voiceprint…")
            voiceprintStatus = "Building speaker embedding…"
            let profile = try await voiceprintService.makeProfile(audioURLs: [audioURL])
            try VoiceprintPrototype.save(profile)
            refreshVoiceprintState(profile: profile)
            applyStatus("Voice enrolled")
            overlay.show("Voice enrolled", detail: "Speaker embedding saved")
            overlay.hide(after: 1_200)
        } catch {
            voiceprintStatus = "Enroll error: \(error.localizedDescription)"
            applyStatus(voiceprintStatus)
            overlay.show(AppBrand.errorTitle, detail: error.localizedDescription)
        }
    }

    private func runVoiceprintVerification() async {
        guard voiceprintProfileExists else {
            voiceprintStatus = "No voice enrolled"
            return
        }
        guard await beginVoiceprintAction() else { return }
        defer { voiceprintBusy = false }

        do {
            let profile = try VoiceprintPrototype.loadProfile()
            applyStatus("Voice verify — speak for 5s")
            overlay.show("Voice verify", detail: "Speak normally for 5 seconds")
            let audioURL = try await recordVoiceprintClip(seconds: 5)
            voiceprintTemporaryAudioURL = audioURL
            defer { removeVoiceprintTemporaryAudio() }
            applyStatus("Verifying voice…")
            voiceprintStatus = "Comparing speaker embedding…"
            let result = try await voiceprintService.verify(
                audioURL: audioURL,
                against: profile,
                thresholdOverride: Float(config.voiceprintThreshold)
            )
            let verdict = result.accepted ? "Accepted" : "Rejected"
            let detail = String(format: "distance %.2f / threshold %.2f", result.distance, result.threshold)
            voiceprintStatus = "\(verdict) — \(detail)"
            applyStatus("Voice \(verdict.lowercased())")
            overlay.show("Voice \(verdict.lowercased())", detail: detail)
            overlay.hide(after: 1_500)
        } catch {
            voiceprintStatus = "Verify error: \(error.localizedDescription)"
            applyStatus(voiceprintStatus)
            overlay.show(AppBrand.errorTitle, detail: error.localizedDescription)
        }
    }

    private func beginVoiceprintAction() async -> Bool {
        guard !voiceprintBusy, audioPreparationTask == nil else { return false }
        guard !config.ambientModeEnabled else {
            voiceprintStatus = "Turn off ambient mode before voiceprint recording."
            overlay.show("Turn off ambient mode", detail: "Then enroll or verify voiceprint")
            overlay.hide(after: 1_500)
            return false
        }
        voiceprintBusy = true
        return true
    }

    private func recordVoiceprintClip(seconds: TimeInterval) async throws -> URL {
        hotkeyMonitor.stop()
        defer {
            audioCapture.stop()
            if started { restartHotkeyMonitor() }
        }
        try await audioCapture.start(preRollMilliseconds: 0, inputDeviceID: config.inputDeviceID)
        audioCapture.beginRecording(bufferHandler: nil, replayPreRollToHandler: false)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return try audioCapture.finishRecording()
    }

    private func refreshVoiceprintState(profile: VoiceprintProfile? = nil) {
        let profile = profile ?? (try? VoiceprintPrototype.loadProfile())
        voiceprintProfileExists = profile != nil
        if let profile {
            voiceprintStatus = String(format: "Enrolled — %dD threshold %.2f", profile.embedding.count, profile.threshold)
        } else {
            voiceprintStatus = "No voice enrolled"
        }
    }
}
