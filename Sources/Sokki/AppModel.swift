import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var statusText = "Starting…"
    @Published private(set) var lastTranscript: String?
    @Published private(set) var liveTranscript: String?
    @Published private(set) var hotkeyStatus = "Right Command"
    @Published private(set) var permissionStatus = PermissionStatus.current()
    @Published private(set) var modelLoading = false
    @Published private(set) var modelReady = false
    @Published var config: SokkiConfig {
        didSet {
            config.save()
            if oldValue.preferredBackend != config.preferredBackend {
                modelReady = false
                modelLoading = true
                dictationController.prepareASR()
            }
            if oldValue.ambientModeEnabled != config.ambientModeEnabled {
                dictationController.updateAmbientMode()
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
    private var started = false

    init() {
        config = SokkiConfig.load()

        asrService = ASRService { [weak self] status in
            Task { @MainActor in
                self?.applyStatus(status, updateModelState: true)
            }
        }
        dictationController = DictationController(
            configProvider: { [weak self] in self?.config ?? .defaults },
            audioCapture: audioCapture,
            asrService: asrService,
            textInserter: textInserter,
            history: history,
            overlay: overlay,
            onStatus: { [weak self] status in self?.applyStatus(status, updateModelState: true) },
            onTranscript: { [weak self] transcript in self?.lastTranscript = transcript },
            onPartialTranscript: { [weak self] transcript in self?.liveTranscript = transcript }
        )
        hotkeyMonitor = HotkeyMonitor(
            keyCode: config.hotkeyKeyCode,
            onKeyDown: { [weak self] in self?.dictationController.hotkeyDown() },
            onKeyUp: { [weak self] in self?.dictationController.hotkeyUp() },
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
            hotkeyStatus = "Right Command active"
            refreshPermissions()
        } catch {
            refreshPermissions()
            applyStatus("Hotkey error: \(error.localizedDescription)", updateModelState: false)
            hotkeyStatus = "Needs Accessibility permission"
            overlay.show("Hotkey error", detail: error.localizedDescription)
            return
        }

        dictationController.prepareASR()
        dictationController.updateAmbientMode()
    }

    private func applyStatus(_ status: String, updateModelState: Bool) {
        statusText = status
        guard updateModelState else { return }

        let lowercased = status.lowercased()
        if lowercased.contains("preparing") || lowercased.contains("loading") || lowercased.contains("starting") {
            modelLoading = true
            modelReady = false
        } else if lowercased.contains("ready") || lowercased.contains("loaded") {
            modelLoading = false
            modelReady = true
        } else if lowercased.contains("asr error") || lowercased.contains("mlx error") || lowercased.contains("apple speech error") {
            modelLoading = false
            modelReady = false
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
