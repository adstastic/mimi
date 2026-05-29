import AVFoundation
import ApplicationServices
import CoreGraphics

struct PermissionStatus: Equatable {
    var microphone: Bool
    var accessibility: Bool
    var inputMonitoring: Bool

    static func current() -> PermissionStatus {
        PermissionStatus(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess()
        )
    }
}
