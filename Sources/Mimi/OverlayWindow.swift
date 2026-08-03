import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    private let state = OverlayState()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ message: String, detail: String? = nil, level: Double? = nil) {
        ensurePanel()
        hideTask?.cancel()
        state.message = message
        state.detail = detail
        state.level = level
        state.isVisible = true
        positionPanel()
        panel?.orderFrontRegardless()

        let lowercased = "\(message) \(detail ?? "")".lowercased()
        if lowercased.contains("error") || lowercased.contains("no speech") {
            hide(after: 4_000)
        } else if lowercased.contains("inserted")
            || lowercased.contains("retried")
            || lowercased.contains("copied")
            || lowercased.contains("cancelled") {
            hide(after: 1_200)
        }
    }

    func updateLevel(_ level: Double) {
        guard state.isVisible else { return }
        state.level = level
    }

    func updateDetail(_ detail: String?) {
        guard state.isVisible else { return }
        state.detail = detail
    }

    func hide(after milliseconds: Int = 0) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            if milliseconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
            }
            await MainActor.run {
                self?.state.isVisible = false
                self?.panel?.orderOut(nil)
            }
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let size = NSSize(width: 420, height: 74)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: OverlayPillView(state: state) { [weak self] in
            self?.hide()
        })
        self.panel = panel
    }

    private func positionPanel() {
        guard let panel else { return }
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let frame = NSRect(
            x: screenFrame.midX - panel.frame.width / 2,
            y: screenFrame.minY + 36,
            width: panel.frame.width,
            height: panel.frame.height
        )
        panel.setFrame(frame, display: true)
    }
}

@MainActor
private final class OverlayState: ObservableObject {
    @Published var isVisible = false
    @Published var message = ""
    @Published var detail: String?
    @Published var level: Double?
}

private struct OverlayPillView: View {
    @ObservedObject var state: OverlayState
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.message)
                    .font(.system(size: 14, weight: .semibold))
                if let detail = state.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            if let level = state.level {
                LevelMeter(level: level)
                    .frame(width: 112, height: 24)
            }

            if showsDismissButton {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: 420, height: 74)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
        .opacity(state.isVisible ? 1 : 0)
    }

    private var showsDismissButton: Bool {
        let text = "\(state.message) \(state.detail ?? "")".lowercased()
        return text.contains("error") || text.contains("no speech")
    }

    private var dotColor: Color {
        if state.message.localizedCaseInsensitiveContains("error") { return .orange }
        if state.message.localizedCaseInsensitiveContains("transcribing") { return .blue }
        if state.message.localizedCaseInsensitiveContains("inserted") { return .green }
        return .red
    }
}

private struct LevelMeter: View {
    let level: Double
    @State private var amplitudes = [Double](repeating: 0, count: 16)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<amplitudes.count, id: \.self) { index in
                Capsule().fill(Color.red.opacity(0.85))
                    .scaleEffect(y: amplitudes[index], anchor: .center)
                    .animation(.smooth(duration: 0.14), value: amplitudes[index])
            }
        }
        .onChange(of: level, initial: true) { _, level in
            amplitudes.removeFirst()
            amplitudes.append(min(1, max(0, (level + 60) / 42)))
        }
    }
}
