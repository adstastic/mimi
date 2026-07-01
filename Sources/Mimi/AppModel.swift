import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var statusText = "Starting…"
    @Published private(set) var lastTranscript: String?
    @Published private(set) var liveTranscript: String?
    @Published private(set) var permissionStatus = PermissionStatus.current()
    @Published private(set) var inputDevices = AudioInputDevice.available()
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
                    dictationController.updateAmbientMode()
                }
            }
            if oldValue.ambientModeEnabled != config.ambientModeEnabled {
                dictationController.updateAmbientMode()
            }
            if oldValue.inputDeviceID != config.inputDeviceID || oldValue.silenceDetectionMode != config.silenceDetectionMode {
                dictationController.updateAmbientMode()
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
    private let overlay = OverlayWindowController()
    private var asrService: ASRService!
    private var dictationController: DictationController!
    private var hotkeyMonitor: HotkeyMonitor!
    private var inputDeviceTask: Task<Void, Never>?
    private var lastDefaultInputDeviceID = AudioInputDevice.defaultInputDeviceUID()
    private var started = false
    private var shortcutRecording = false

    init() {
        config = MimiConfig.load()

        asrService = ASRService { [weak self] status in
            Task { @MainActor in
                self?.applyStatus(status)
            }
        }
        dictationController = DictationController(
            configProvider: { [weak self] in self?.config ?? .defaults },
            audioCapture: audioCapture,
            asrService: asrService,
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

        NSApplication.shared.setActivationPolicy(.regular)

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
        dictationController.updateAmbientMode()
        startInputDeviceWatcher()
    }

    func refreshInputDevices() {
        inputDevices = AudioInputDevice.available()
        lastDefaultInputDeviceID = AudioInputDevice.defaultInputDeviceUID()
        if config.ambientModeEnabled {
            dictationController.updateAmbientMode()
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
                    if (devicesChanged || defaultChanged), self.config.ambientModeEnabled {
                        self.dictationController.updateAmbientMode()
                    }
                }
            }
        }
    }

    private func applyStatus(_ status: String) {
        statusText = status
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

    func cancelRecording() {
        dictationController.cancelRecording()
    }
}
