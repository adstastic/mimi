import AVFoundation
import Foundation

final class AudioCapture {
    enum CaptureError: LocalizedError {
        case microphoneDenied
        case missingInputChannel
        case noRecordedAudio
        case outputBufferFailed

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "Microphone permission is required."
            case .missingInputChannel:
                "No microphone input channel was available."
            case .noRecordedAudio:
                "No audio was recorded."
            case .outputBufferFailed:
                "Could not create output audio buffer."
            }
        }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var tapInstalled = false
    private var ringSamples: [Float] = []
    private var recordingSamples: [Float] = []
    private var ringCapacity = 0
    private var recording = false
    private var recordingBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var sampleRate: Double = 48_000
    private var latestDBFS: Double = -120

    func start(preRollMilliseconds: Int) async throws {
        guard try await Self.requestMicrophoneAccess() else {
            throw CaptureError.microphoneDenied
        }

        if engine.isRunning { return }

        resetBuffersForStart()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        ringCapacity = max(1, Int(sampleRate * Double(preRollMilliseconds) / 1_000.0))

        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
                self?.handle(buffer: buffer)
            }
            tapInstalled = true
        }

        engine.prepare()
        try engine.start()
    }

    func beginRecording(bufferHandler: ((AVAudioPCMBuffer) -> Void)? = nil) {
        lock.lock()
        recordingSamples = ringSamples
        recordingBufferHandler = bufferHandler
        recording = true
        lock.unlock()
    }

    func finishRecording() throws -> URL {
        let samples: [Float]
        let rate: Double

        lock.lock()
        recording = false
        samples = recordingSamples
        recordingSamples = []
        recordingBufferHandler = nil
        rate = sampleRate
        lock.unlock()

        guard !samples.isEmpty else { throw CaptureError.noRecordedAudio }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sokki-")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.writeWAV(samples: samples, sampleRate: rate, to: url)
        return url
    }

    func cancelRecording() {
        lock.lock()
        recording = false
        recordingSamples = []
        recordingBufferHandler = nil
        lock.unlock()
    }

    func stop() {
        engine.stop()
        lock.lock()
        recording = false
        recordingSamples = []
        ringSamples = []
        recordingBufferHandler = nil
        latestDBFS = -120
        lock.unlock()
    }

    func currentDBFS() -> Double {
        lock.lock()
        let value = latestDBFS
        lock.unlock()
        return value
    }

    private func resetBuffersForStart() {
        lock.lock()
        ringSamples = []
        recordingSamples = []
        latestDBFS = -120
        lock.unlock()
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        let samples = Array(UnsafeBufferPointer(start: channel, count: count))
        var squareSum: Float = 0
        for sample in samples {
            squareSum += sample * sample
        }
        let rms = sqrt(squareSum / Float(count))
        let dbfs = 20 * log10(Double(max(rms, 0.000_001)))

        let copiedBuffer = buffer.copy() as? AVAudioPCMBuffer

        let handler: ((AVAudioPCMBuffer) -> Void)?
        lock.lock()
        latestDBFS = max(-120, dbfs)
        if recording {
            recordingSamples.append(contentsOf: samples)
            handler = recordingBufferHandler
        } else {
            handler = nil
            ringSamples.append(contentsOf: samples)
            if ringSamples.count > ringCapacity {
                ringSamples.removeFirst(ringSamples.count - ringCapacity)
            }
        }
        lock.unlock()

        if let handler, let copiedBuffer {
            handler(copiedBuffer)
        }
    }

    private static func writeWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw CaptureError.outputBufferFailed
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let destination = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { pointer in
                destination.update(from: pointer.baseAddress!, count: samples.count)
            }
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func requestMicrophoneAccess() async throws -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
