import AppKit
import Combine
import Foundation
import MimiSpeech

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var statusText = "Starting…"
    @Published private(set) var lastTranscript: String?
    @Published private(set) var liveTranscript: String?
    @Published private(set) var permissionStatus = PermissionStatus.current()
    @Published private(set) var inputDevices = AudioInputDevice.available()
    @Published private(set) var voiceprintStatus = "No voice enrolled"
    @Published private(set) var voiceprintProfileExists = false
    @Published private(set) var voiceprintBusy = false
    @Published var config: MimiConfig {
        didSet {
            let normalized = config.normalizedForBackend()
            if normalized != config {
                config = normalized
            }
            config.save()
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
                || oldValue.ambientToggleShortcut != config.ambientToggleShortcut {
                restartHotkeyMonitor()
            }
        }
    }

    let history = HistoryStore()

    private let audioCapture = AudioCapture()
    private let textInserter = TextInserter()
    private let voiceprintService = VoiceprintEmbeddingService()
    private var voiceprintVerifier: FileVoiceprintVerifier!
    private let overlay = OverlayWindowController()
    private var asrService: ASRService!
    private var dictationController: DictationController!
    private var hotkeyMonitor: HotkeyMonitor!
    private var wakeCancellable: AnyCancellable?
    private var inputDeviceTask: Task<Void, Never>?
    private var ambientModeUpdateTask: Task<Void, Never>?
    private var audioPreparationTask: Task<Void, Never>?
    private var lastDefaultInputDeviceID = AudioInputDevice.defaultInputDeviceUID()
    private var started = false
    private var shortcutRecording = false

    init() {
        let loadedInputDevices = AudioInputDevice.available()
        var loadedConfig = MimiConfig.load()
        let validInputDeviceID = AudioInputDevice.validSelection(loadedConfig.inputDeviceID, in: loadedInputDevices)
        if validInputDeviceID != loadedConfig.inputDeviceID {
            loadedConfig.inputDeviceID = validInputDeviceID
            loadedConfig.save()
        }
        config = loadedConfig
        inputDevices = loadedInputDevices
        refreshVoiceprintState()

        asrService = ASRService { [weak self] status in
            Task { @MainActor in
                self?.applyStatus(status)
            }
        }
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
            onPartialTranscript: { [weak self] transcript in self?.liveTranscript = transcript }
        )
        hotkeyMonitor = HotkeyMonitor(
            dictationShortcut: config.dictationShortcut,
            ambientToggleShortcut: config.ambientToggleShortcut,
            onDictationDown: { [weak self] in self?.dictationController.hotkeyDown() },
            onDictationUp: { [weak self] in self?.dictationController.hotkeyUp() },
            onAmbientToggle: { [weak self] in self?.toggleAmbientModeFromShortcut() },
            onCancel: { [weak self] in self?.dictationController.cancelRecording() }
        )

        Task { await start() }
    }

    func start() async {
        guard !started else { return }
        started = true

        NSApplication.shared.setActivationPolicy(.accessory)

        refreshPermissions()

        do {
            refreshPermissions()
            try hotkeyMonitor.start()
            refreshPermissions()
        } catch {
            refreshPermissions()
            applyStatus("Hotkey error: \(error.localizedDescription)")
            overlay.show(AppBrand.hotkeyErrorTitle, detail: error.localizedDescription)
            return
        }

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
                    let devicesChanged = devices != self.inputDevices
                    let defaultChanged = defaultInputDeviceID != self.lastDefaultInputDeviceID
                    if devicesChanged {
                        self.inputDevices = devices
                    }
                    if defaultChanged {
                        self.lastDefaultInputDeviceID = defaultInputDeviceID
                    }
                    let resetMissingDevice = self.resetMissingSelectedInputDevice()
                    if (devicesChanged || defaultChanged), self.config.ambientModeEnabled, !resetMissingDevice {
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
            ambientToggleShortcut: config.ambientToggleShortcut
        )
        guard started else { return }
        hotkeyMonitor.stop()
        do {
            try hotkeyMonitor.start()
        } catch {
            applyStatus("Hotkey error: \(error.localizedDescription)")
            overlay.show(AppBrand.hotkeyErrorTitle, detail: error.localizedDescription)
        }
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
    }

    func copyLastTranscript() {
        dictationController.copyLastTranscript()
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
