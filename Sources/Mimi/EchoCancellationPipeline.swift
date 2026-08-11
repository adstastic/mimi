import Foundation

final class EchoCancellationPipeline {
    private let processingQueue = DispatchQueue(label: "com.ad1.mimi.echo-processing", qos: .userInteractive)
    private let tapQueue = DispatchQueue(label: "com.ad1.mimi.system-audio-tap-control", qos: .userInitiated)
    private let tapIOQueue = DispatchQueue(label: "com.ad1.mimi.system-audio-tap-io", qos: .userInitiated)
    private var stream: EchoCancellationStream?
    private var active = false
    private var tap: SystemAudioTap?

    func start(systemAudioReferenceEnabled: Bool = true) {
        processingQueue.async { [self] in
            active = systemAudioReferenceEnabled
            stream = systemAudioReferenceEnabled ? EchoCancellationStream() : nil
        }
        tapQueue.async { [self] in
            tap?.stop()
            tap = nil
            guard systemAudioReferenceEnabled else {
                DebugLog.write("echo reference bypassed for Bluetooth output")
                return
            }

            let newTap = SystemAudioTap()
            do {
                try newTap.start(on: tapIOQueue) { [weak self] samples, sampleRate, _ in
                    self?.processingQueue.async { [weak self] in
                        guard let self, active else { return }
                        stream?.processRender(samples, sampleRate: sampleRate)
                    }
                }
                tap = newTap
                DebugLog.write("echo reference started")
            } catch {
                newTap.stop()
                tap = nil
                DebugLog.write("echo reference unavailable: \(error.localizedDescription)")
            }
        }
    }

    func processCapture(_ samples: [Float], sampleRate: Int32) -> [Float] {
        processingQueue.sync {
            guard active, let stream else { return samples }
            return stream.processCapture(samples, sampleRate: sampleRate)
        }
    }

    func flushCapture() -> [Float] {
        processingQueue.sync {
            guard active, let stream else { return [] }
            return stream.flushCapture()
        }
    }

    func stop() {
        processingQueue.sync {
            active = false
            stream = nil
        }
        tapQueue.async { [self] in
            tap?.stop()
            tap = nil
        }
    }
}
