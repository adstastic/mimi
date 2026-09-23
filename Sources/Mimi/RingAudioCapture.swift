import AVFoundation
import Combine
import Foundation
import RingKit

/// Familiar Ring as a dictation input. The Ring streams Opus over BLE only while
/// its button is held, and its START/STOP markers drive dictation directly, so
/// no hotkey is involved when this source is selected.
final class RingAudioCapture: ObservableObject, AudioCapturing, @unchecked Sendable {
    static let deviceID = "familiar-ring"
    static let deviceName = "Familiar Ring"
    private static let sampleRate = Double(RingCodec.sampleRate)
    private static let connectTimeout: TimeInterval = 10

    @Published private(set) var readiness: RingConnectionReadiness = .idle

    @MainActor var onPressBegan: @MainActor () -> Void = {}
    @MainActor var onPressEnded: @MainActor () -> Void = {}
    @MainActor var onPressCancelled: @MainActor () -> Void = {}

    // ponytail: the sample bookkeeping below duplicates AudioCapture.handle(buffer:)
    // and friends. Extract a shared type when a third source appears.
    private let lock = NSLock()
    private var ringSamples: [Float] = []
    private var recordingSamples: [Float] = []
    private var ringCapacity = 0
    private var recording = false
    private var recordingBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var monitorBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var latestDBFS: Double = -120
    private var recentLevels: [(date: Date, dbfs: Double)] = []
    private var lastBufferAt: Date?
    private var decoder = NativeAudioPayloadDecoder()
    private var codec: RingCodec

    /// Created on first `start()` so tests and idle launches never touch CoreBluetooth.
    private var ble: BLECentralService?
    private var readinessCancellable: AnyCancellable?

    init(codec: RingCodec = .firmwareDefault) {
        self.codec = codec
    }

    @MainActor
    private func service() -> BLECentralService {
        if let ble { return ble }
        let ble = BLECentralService(
            recordingConfiguration: .default,
            onDisconnect: { cause in DebugLog.write("ring disconnect cause=\(cause)") }
        ) { [weak self] delivery in
            self?.handle(delivery.notification)
        }
        readinessCancellable = ble.$readiness
            .combineLatest(ble.$currentCodec)
            .receive(on: RunLoop.main)
            .sink { [weak self] readiness, codec in
                guard let self else { return }
                if readiness != self.readiness { DebugLog.write("ring readiness=\(readiness.rawValue)") }
                self.readiness = readiness
                self.lock.lock()
                self.codec = codec
                self.lock.unlock()
            }
        self.ble = ble
        return ble
    }

    func setPreRoll(milliseconds: Int) {
        lock.lock()
        ringCapacity = max(1, Int(Self.sampleRate * Double(milliseconds) / 1_000))
        ringSamples = []
        recordingSamples = []
        latestDBFS = -120
        recentLevels = []
        lastBufferAt = nil
        lock.unlock()
    }

    @MainActor
    func start(preRollMilliseconds: Int, inputDeviceID: String?) async throws {
        setPreRoll(milliseconds: preRollMilliseconds)

        let ble = service()
        guard ble.readiness != .audioSubscribed else { return }
        DebugLog.write("ring start readiness=\(ble.readiness.rawValue) selected=\(ble.selectedPeripheralID?.uuidString ?? "none")")

        let deadline = Date().addingTimeInterval(Self.connectTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            switch ble.readiness {
            case .audioSubscribed:
                return
            case .idle, .bluetoothUnavailable, .disconnected:
                // CBCentralManager reports poweredOn asynchronously after creation and
                // startScanning() refuses until then, so keep asking until it takes.
                ble.startScanning()
                if ble.selectedPeripheralID != nil { ble.reconnectSelected() }
            case .scanning:
                if ble.selectedPeripheralID == nil,
                   let strongest = ble.discoveredDevices.max(by: { $0.rssi < $1.rssi }) {
                    DebugLog.write("ring select name=\(strongest.name) rssi=\(strongest.rssi)")
                    ble.select(deviceID: strongest.id)
                }
            case .connecting, .connected, .discovered:
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        DebugLog.write("ring start timeout readiness=\(ble.readiness.rawValue)")
        throw AudioCapture.CaptureError.inputDeviceUnavailable
    }

    /// Drops the BLE link. The phone can take the Ring back after this.
    @MainActor
    func release() {
        ble?.disconnect()
    }

    // MARK: Notifications

    func handle(_ notification: RingNotification) {
        switch notification {
        case let .recordingEvent(event):
            DebugLog.write("ring event marker=\(event.marker) session=\(event.sessionID)")
            switch event.marker {
            case .start, .altStart:
                lock.lock()
                decoder = NativeAudioPayloadDecoder()
                lock.unlock()
                Task { @MainActor in self.onPressBegan() }
            case .stop:
                Task { @MainActor in self.onPressEnded() }
            case .cancel:
                Task { @MainActor in self.onPressCancelled() }
            }
        case let .audioPacket(packet):
            lock.lock()
            let decoder = decoder
            let codec = codec
            lock.unlock()
            let pcm: Data
            do {
                pcm = try decoder.decode(packet: packet, codec: codec)
            } catch {
                DebugLog.write("ring decode error packet=\(packet.packetID) reason=\(RingDiagnostics.failureReason(error))")
                return
            }
            let samples = pcm.withUnsafeBytes { raw -> [Float] in
                raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 }
            }
            guard let buffer = AudioCapture.makeBuffer(samples: samples, sampleRate: Self.sampleRate) else { return }
            handle(buffer: buffer, samples: samples)
        case .malformed:
            DebugLog.write("ring malformed notification")
        }
    }

    private func handle(buffer: AVAudioPCMBuffer, samples: [Float]) {
        var squareSum: Float = 0
        for sample in samples {
            squareSum += sample * sample
        }
        let rms = sqrt(squareSum / Float(samples.count))
        let dbfs = 20 * log10(Double(max(rms, 0.000_001)))

        let handler: ((AVAudioPCMBuffer) -> Void)?
        let monitorHandler: ((AVAudioPCMBuffer) -> Void)?
        let receivedAt = Date()
        lock.lock()
        latestDBFS = max(-120, dbfs)
        recentLevels.append((receivedAt, latestDBFS))
        recentLevels.removeAll { receivedAt.timeIntervalSince($0.date) > 2 }
        lastBufferAt = receivedAt
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

        if let handler {
            handler(buffer)
        } else if let monitorHandler {
            monitorHandler(buffer)
        }
    }

    // MARK: AudioCapturing

    @MainActor
    func setMonitorBufferHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        monitorBufferHandler = handler
        lock.unlock()
    }

    @MainActor
    func beginRecording(bufferHandler: ((AVAudioPCMBuffer) -> Void)?, replayPreRollToHandler: Bool) {
        lock.lock()
        let preRollSamples = ringSamples
        recordingSamples = ringSamples
        recordingBufferHandler = bufferHandler
        recording = true
        lock.unlock()

        if replayPreRollToHandler,
           let bufferHandler,
           let preRollBuffer = AudioCapture.makeBuffer(samples: preRollSamples, sampleRate: Self.sampleRate) {
            bufferHandler(preRollBuffer)
        }
    }

    @MainActor
    func finishRecording() throws -> URL {
        lock.lock()
        recording = false
        let samples = recordingSamples
        recordingSamples = []
        recordingBufferHandler = nil
        lock.unlock()

        guard !samples.isEmpty else { throw AudioCapture.CaptureError.noRecordedAudio }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimi-")
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AudioCapture.writeWAV(samples: samples, sampleRate: Self.sampleRate, to: url)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    @MainActor
    func cancelRecording() {
        lock.lock()
        recording = false
        recordingSamples = []
        recordingBufferHandler = nil
        lock.unlock()
    }

    /// Clears capture state only. The BLE link stays up so the next press is heard.
    @MainActor
    func stop() {
        lock.lock()
        recording = false
        recordingSamples = []
        ringSamples = []
        recordingBufferHandler = nil
        monitorBufferHandler = nil
        latestDBFS = -120
        recentLevels = []
        lastBufferAt = nil
        lock.unlock()
    }

    @MainActor
    func currentDBFS() -> Double {
        lock.lock()
        let value = latestDBFS
        lock.unlock()
        return value
    }

    @MainActor
    func peakDBFS(within seconds: TimeInterval) -> Double {
        let cutoff = Date().addingTimeInterval(-seconds)
        lock.lock()
        let value = recentLevels.reduce(-120) { peak, level in
            level.date >= cutoff ? max(peak, level.dbfs) : peak
        }
        lock.unlock()
        return value
    }

    @MainActor
    func secondsSinceLastBuffer() -> TimeInterval? {
        lock.lock()
        let lastBufferAt = lastBufferAt
        lock.unlock()
        guard let lastBufferAt else { return nil }
        return Date().timeIntervalSince(lastBufferAt)
    }
}

/// Picks the microphone or the Ring per `inputDeviceID` at `start()` and forwards
/// everything else to whichever source is active.
@MainActor
final class RoutingAudioCapture: AudioCapturing {
    private let mic: any AudioCapturing
    private let ring: any AudioCapturing
    private(set) var active: any AudioCapturing

    init(mic: any AudioCapturing, ring: any AudioCapturing) {
        self.mic = mic
        self.ring = ring
        active = mic
    }

    func start(preRollMilliseconds: Int, inputDeviceID: String?) async throws {
        let next: any AudioCapturing = inputDeviceID == RingAudioCapture.deviceID ? ring : mic
        if next !== active {
            active.stop()
            active = next
        }
        try await active.start(preRollMilliseconds: preRollMilliseconds, inputDeviceID: inputDeviceID)
    }

    func setMonitorBufferHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        active.setMonitorBufferHandler(handler)
    }

    func beginRecording(bufferHandler: ((AVAudioPCMBuffer) -> Void)?, replayPreRollToHandler: Bool) {
        active.beginRecording(bufferHandler: bufferHandler, replayPreRollToHandler: replayPreRollToHandler)
    }

    func finishRecording() throws -> URL { try active.finishRecording() }
    func cancelRecording() { active.cancelRecording() }
    func stop() { active.stop() }
    func currentDBFS() -> Double { active.currentDBFS() }
    func peakDBFS(within seconds: TimeInterval) -> Double { active.peakDBFS(within: seconds) }
    func secondsSinceLastBuffer() -> TimeInterval? { active.secondsSinceLastBuffer() }
}
