import AudioUnit
import AVFoundation
import Foundation

final class AudioCapture {
    enum CaptureError: LocalizedError {
        case microphoneDenied
        case missingInputChannel
        case inputDeviceUnavailable
        case noRecordedAudio
        case outputBufferFailed

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                "Microphone permission is required."
            case .missingInputChannel:
                "No microphone input channel was available."
            case .inputDeviceUnavailable:
                "Selected microphone is not available."
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
    private var starting = false
    private var startSeq = 0
    private var ringSamples: [Float] = []
    private var recordingSamples: [Float] = []
    private var ringCapacity = 0
    private var recording = false
    private var recordingBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var monitorBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var sampleRate: Double = 48_000
    private var latestDBFS: Double = -120
    private var lastBufferAt: Date?
    private var lastMonitorLogAt = Date.distantPast

    @MainActor
    func start(preRollMilliseconds: Int, inputDeviceID: String?) async throws {
        guard try await Self.requestMicrophoneAccess() else {
            throw CaptureError.microphoneDenied
        }
        try Task.checkCancellation()

        // Serialize on the main actor and reject re-entry: ambient mode restarts
        // the mic from a 2s watchdog, config changes, and the device watcher,
        // any of which can call start() while another is mid-flight. Two taps
        // on the same bus makes installTap raise an uncatchable Obj-C exception
        // that aborts the process. The guard is set with no await before it, so
        // it is atomic on the main actor.
        if engine.isRunning || starting { return }
        starting = true
        defer { starting = false }
        startSeq += 1
        let seq = startSeq

        resetBuffersForStart()

        let input = engine.inputNode
        try applyInputDevice(inputDeviceID, to: input)

        // A just-switched HAL device can momentarily report an invalid format
        // (0 Hz / 0 ch); installTap aborts on that too. Let it settle, then
        // bail cleanly if it never does.
        var format = input.outputFormat(forBus: 0)
        var settleAttempts = 0
        while !Self.isValid(format), settleAttempts < 15 {
            try await Task.sleep(nanoseconds: 20_000_000)
            try Task.checkCancellation()
            format = input.outputFormat(forBus: 0)
            settleAttempts += 1
        }
        try Task.checkCancellation()
        DebugLog.write(String(format: "audio start #%d running=%@ tap=%@ sr=%.0f ch=%d settle=%d",
                              seq, engine.isRunning ? "Y" : "N", tapInstalled ? "Y" : "N",
                              format.sampleRate, format.channelCount, settleAttempts))
        guard Self.isValid(format) else { throw CaptureError.inputDeviceUnavailable }
        sampleRate = format.sampleRate
        ringCapacity = max(1, Int(sampleRate * Double(preRollMilliseconds) / 1_000.0))

        // Defensively clear any stale tap before installing — removeTap on a bus
        // with no tap is a safe no-op, and it prevents a flag/engine desync from
        // double-installing.
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
    }

    func setMonitorBufferHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        monitorBufferHandler = handler
        lock.unlock()
    }

    func beginRecording(
        bufferHandler: ((AVAudioPCMBuffer) -> Void)? = nil,
        replayPreRollToHandler: Bool = true
    ) {
        let preRollSamples: [Float]
        let rate: Double

        lock.lock()
        preRollSamples = ringSamples
        rate = sampleRate
        recordingSamples = ringSamples
        recordingBufferHandler = bufferHandler
        recording = true
        lock.unlock()

        if replayPreRollToHandler,
           let bufferHandler,
           let preRollBuffer = Self.makeBuffer(samples: preRollSamples, sampleRate: rate) {
            bufferHandler(preRollBuffer)
        }
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
            .appendingPathComponent("mimi-")
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

    @MainActor
    func stop() {
        DebugLog.write("audio stop running=\(engine.isRunning ? "Y" : "N") tap=\(tapInstalled ? "Y" : "N")")
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        lock.lock()
        recording = false
        recordingSamples = []
        ringSamples = []
        recordingBufferHandler = nil
        monitorBufferHandler = nil
        latestDBFS = -120
        lastBufferAt = nil
        lock.unlock()
    }

    func currentDBFS() -> Double {
        lock.lock()
        let value = latestDBFS
        lock.unlock()
        return value
    }

    func secondsSinceLastBuffer() -> TimeInterval? {
        lock.lock()
        let lastBufferAt = lastBufferAt
        lock.unlock()
        guard let lastBufferAt else { return nil }
        return Date().timeIntervalSince(lastBufferAt)
    }

    private func resetBuffersForStart() {
        lock.lock()
        ringSamples = []
        recordingSamples = []
        latestDBFS = -120
        lastBufferAt = nil
        lock.unlock()
    }

    private static func isValid(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    private func applyInputDevice(_ inputDeviceID: String?, to input: AVAudioInputNode) throws {
        guard let inputDeviceID, !inputDeviceID.isEmpty else { return }
        guard var deviceID = AudioInputDevice.deviceID(for: inputDeviceID) else {
            throw CaptureError.inputDeviceUnavailable
        }
        guard let audioUnit = input.audioUnit else {
            throw CaptureError.missingInputChannel
        }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw CaptureError.inputDeviceUnavailable
        }
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
        let monitorHandler: ((AVAudioPCMBuffer) -> Void)?
        lock.lock()
        latestDBFS = max(-120, dbfs)
        lastBufferAt = Date()
        if recording {
            recordingSamples.append(contentsOf: samples)
            handler = recordingBufferHandler
            monitorHandler = nil
        } else {
            handler = nil
            monitorHandler = monitorBufferHandler
            ringSamples.append(contentsOf: samples)
            if ringSamples.count > ringCapacity {
                ringSamples.removeFirst(ringSamples.count - ringCapacity)
            }
        }
        lock.unlock()

        if let copiedBuffer {
            if let handler {
                handler(copiedBuffer)
            } else if let monitorHandler {
                let now = Date()
                if now.timeIntervalSince(lastMonitorLogAt) >= 1 {
                    lastMonitorLogAt = now
                    DebugLog.write(String(format: "audio monitor buffer frames=%d dbfs=%.1f", copiedBuffer.frameLength, latestDBFS))
                }
                monitorHandler(copiedBuffer)
            }
        }
    }

    private static func writeWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let buffer = makeBuffer(samples: samples, sampleRate: sampleRate) else {
            throw CaptureError.outputBufferFailed
        }

        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)
    }

    private static func makeBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: 1,
                  interleaved: false
              ), let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let destination = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { pointer in
                destination.update(from: pointer.baseAddress!, count: samples.count)
            }
        }
        return buffer
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
