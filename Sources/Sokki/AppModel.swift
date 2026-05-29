import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var statusText = "Starting…"
    @Published private(set) var lastTranscript: String?
    @Published private(set) var hotkeyStatus = "Right Option"
    @Published private(set) var permissionStatus = PermissionStatus.current()
    @Published private(set) var modelLoading = false
    @Published private(set) var modelReady = false
    @Published var config: SokkiConfig {
        didSet { config.save() }
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
                self?.statusText = status
                self?.modelLoading = status.localizedCaseInsensitiveContains("loading")
                self?.modelReady = status.localizedCaseInsensitiveContains("ready")
            }
        }
        dictationController = DictationController(
            configProvider: { [weak self] in self?.config ?? .defaults },
            audioCapture: audioCapture,
            asrService: asrService,
            textInserter: textInserter,
            history: history,
            overlay: overlay,
            onStatus: { [weak self] status in self?.statusText = status },
            onTranscript: { [weak self] transcript in self?.lastTranscript = transcript }
        )
        hotkeyMonitor = HotkeyMonitor(
            keyCode: config.hotkeyKeyCode,
            onKeyDown: { [weak self] in self?.dictationController.hotkeyDown() },
            onKeyUp: { [weak self] in self?.dictationController.hotkeyUp() }
        )

        Task { await start() }
    }

    func start() async {
        guard !started else { return }
        started = true

        NSApplication.shared.setActivationPolicy(.regular)

        refreshPermissions()

        do {
            statusText = "Starting microphone…"
            try await audioCapture.start(preRollMilliseconds: config.preRollMilliseconds)
            refreshPermissions()
        } catch {
            refreshPermissions()
            statusText = "Mic error: \(error.localizedDescription)"
            overlay.show("Mic error", detail: error.localizedDescription)
            return
        }

        do {
            refreshPermissions()
            try hotkeyMonitor.start()
            hotkeyStatus = "Right Option active"
            refreshPermissions()
        } catch {
            refreshPermissions()
            statusText = "Hotkey error: \(error.localizedDescription)"
            hotkeyStatus = "Needs Accessibility permission"
            overlay.show("Hotkey error", detail: error.localizedDescription)
            return
        }

        dictationController.prepareASR()
    }

    func refreshPermissions() {
        permissionStatus = PermissionStatus.current()
    }

    func retryLastInsert() {
        dictationController.retryLastInsert()
    }

    func copyLastTranscript() {
        dictationController.copyLastTranscript()
    }

    func cancelRecording() {
        dictationController.cancelRecording()
    }
}
