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

    // Link health per session: the Ring shows red when the Mac drains audio
    // slower than 100 notifications per second, so measure the rate and gaps.
    private var sessionPackets = 0
    private var sessionGaps = 0
    private var sessionFirstAt: Date?
    private var sessionLastAt: Date?
    private var sessionLastPacketID: UInt16?
    /// Pauses over 150 ms between notifications, and the largest one.
    private var sessionStalls = 0
    private var sessionMaxPause: TimeInterval = 0
    /// Frames the Ring produced (100/s) minus frames received, at its worst.
    private var sessionMaxBacklog = 0
    private var sessionGapBuckets = [0, 0, 0, 0, 0]

    /// Between START and beginRecording every packet is speech, so the pre-roll
    /// ring must not trim it. Cleared when recording begins or the press ends.
    private var keepAllSinceStart = false

    /// Created on first `start()` so tests and idle launches never touch CoreBluetooth.
    private var ble: BLECentralService?
    private var readinessCancellable: AnyCancellable?
    private var flagsCancellable: AnyCancellable?
    /// One connect at a time; concurrent start() calls await it.
    @MainActor private var connectTask: Task<Void, Error>?
    @MainActor private var pendingDisconnect: Task<Void, Never>?
    /// releaseNow() restores the flag once per link.
    @MainActor private var releasedThisLink = false

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
        // The phone records blue and magenta. White on the Ring means "held by
        // the Mac". Double press is off: mimi has no second lane for it. The
        // second colour is wire-format filler while double press is off.
        let white = RingColor(red: 128, green: 128, blue: 128)
        // Double press is off: mimi has no second lane for it. The hand-off
        // gesture lives in the Ring firmware (triple tap and hold), not here.
        ble.recordingConfigCommandOverride = .recordingConfig(doublePressEnabled: false, single: white, double: white)
        readinessCancellable = ble.$readiness
            .combineLatest(ble.$currentCodec)
            .receive(on: RunLoop.main)
            .sink { [weak self] readiness, codec in
                guard let self else { return }
                if readiness != self.readiness { DebugLog.write("ring readiness=\(readiness.rawValue)") }
                if readiness == .audioSubscribed { self.releasedThisLink = false }
                self.readiness = readiness
                self.lock.lock()
                self.codec = codec
                self.lock.unlock()
            }
        flagsCancellable = ble.$captureFlagsSupported
            .combineLatest(ble.$observedCaptureFlags, ble.$captureFlagsError, ble.$firmwareRevision)
            .receive(on: RunLoop.main)
            .removeDuplicates { $0 == $1 }
            .sink { supported, observed, error, firmware in
                DebugLog.write("ring flags supported=\(supported) observed=\(observed.map { String(format: "0x%04x", $0.rawValue) } ?? "nil") error=\(error ?? "nil") firmware=\(firmware ?? "nil")")
            }
        self.ble = ble
        return ble
    }

    /// Capacity plus a clean slate: for a fresh link, and for tests.
    func setPreRoll(milliseconds: Int) {
        lock.lock()
        ringCapacity = max(1, Int(Self.sampleRate * Double(milliseconds) / 1_000))
        ringSamples = []
        recordingSamples = []
        latestDBFS = -120
        recentLevels = []
        lastBufferAt = nil
        keepAllSinceStart = false
        lock.unlock()
    }

    /// Capacity only. A press already in flight keeps its samples.
    private func setPreRollCapacity(milliseconds: Int) {
        lock.lock()
        ringCapacity = max(1, Int(Self.sampleRate * Double(milliseconds) / 1_000))
        lock.unlock()
    }

    @MainActor
    func start(preRollMilliseconds: Int, inputDeviceID: String?) async throws {
        pendingDisconnect?.cancel()
        pendingDisconnect = nil
        let ble = service()
        // Every press calls start(). On a live link the START marker and its first
        // packets may already be in, so keep them.
        if ble.readiness == .audioSubscribed {
            setPreRollCapacity(milliseconds: preRollMilliseconds)
            return
        }
        setPreRoll(milliseconds: preRollMilliseconds)
        if let connectTask {
            try await connectTask.value
            return
        }
        let task = Task<Void, Error> { @MainActor in
            defer { self.connectTask = nil }
            try await self.connect(ble)
        }
        connectTask = task
        try await task.value
    }

    @MainActor
    private func connect(_ ble: BLECentralService) async throws {
        DebugLog.write("ring start readiness=\(ble.readiness.rawValue) selected=\(ble.selectedPeripheralID?.uuidString ?? "none")")
        // Firmware 2.8.0 asks for a 30-50 ms connection interval 5 s after connect.
        // macOS sends fewer packets per interval than iOS and drains at ~70/s
        // against the Ring's 100/s, so keep macOS on its own interval while the
        // Mac holds the Ring. release() puts the flag back for the phone.
        ble.setCaptureFlags([])

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
        guard let ble else { return }
        connectTask?.cancel()
        ble.setCaptureFlags(.requestLinkParams)
        // ponytail: give the flag write a moment to land before the link drops.
        // start() cancels this so a re-established link is not dropped.
        pendingDisconnect = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            ble.disconnect()
        }
    }

    /// Quit path: the process is about to exit, so block briefly instead of
    /// scheduling, or the flag write never leaves the queue.
    @MainActor
    func releaseNow() {
        guard let ble, !releasedThisLink,
              ble.readiness != .idle, ble.readiness != .disconnected else { return }
        releasedThisLink = true
        ble.setCaptureFlags(.requestLinkParams)
        Thread.sleep(forTimeInterval: 0.4)
        ble.disconnect()
        Thread.sleep(forTimeInterval: 0.1)
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
                ringSamples = []
                keepAllSinceStart = true
                sessionPackets = 0
                sessionGaps = 0
                sessionFirstAt = nil
                sessionLastAt = nil
                sessionLastPacketID = nil
                sessionStalls = 0
                sessionMaxPause = 0
                sessionMaxBacklog = 0
                sessionGapBuckets = [0, 0, 0, 0, 0]
                lock.unlock()
                Task { @MainActor in self.onPressBegan() }
            case .stop:
                lock.lock()
                keepAllSinceStart = false
                let packets = sessionPackets
                let gaps = sessionGaps
                let elapsed = sessionFirstAt.map { Date().timeIntervalSince($0) } ?? 0
                let stalls = sessionStalls
                let maxPause = sessionMaxPause
                let maxBacklog = sessionMaxBacklog
                let buckets = sessionGapBuckets
                lock.unlock()
                let rate = elapsed > 0 ? Double(packets) / elapsed : 0
                DebugLog.write(String(format: "ring session %d packets=%d gaps=%d elapsed=%.2fs rate=%.1f/s expected=%d stalls=%d max_pause=%.0fms max_backlog=%d gaps_ms[<5,5-20,20-40,40-80,>80]=%@",
                                      Int(event.sessionID), packets, gaps, elapsed, rate, Int(event.packetCount), stalls, maxPause * 1000, maxBacklog, buckets.map(String.init).joined(separator: ",")))
                Task { @MainActor in self.onPressEnded() }
            case .cancel:
                Task { @MainActor in self.onPressCancelled() }
            }
        case let .audioPacket(packet):
            lock.lock()
            let decoder = decoder
            let codec = codec
            let now = Date()
            sessionPackets += 1
            if sessionFirstAt == nil { sessionFirstAt = now }
            if let last = sessionLastAt {
                let pause = now.timeIntervalSince(last)
                if pause > 0.15 { sessionStalls += 1 }
                sessionMaxPause = max(sessionMaxPause, pause)
                // Inter-arrival buckets in ms: <5 same event, 5-20, 20-40, 40-80, >80.
                // The dominant inter-burst bucket is the connection interval.
                let ms = pause * 1000
                let bucket = ms < 5 ? 0 : ms < 20 ? 1 : ms < 40 ? 2 : ms < 80 ? 3 : 4
                sessionGapBuckets[bucket] += 1
            }
            sessionLastAt = now
            if let first = sessionFirstAt {
                let produced = Int(now.timeIntervalSince(first) * 100)
                sessionMaxBacklog = max(sessionMaxBacklog, produced - sessionPackets)
            }
            if let last = sessionLastPacketID, packet.packetID != last &+ 1 { sessionGaps += 1 }
            sessionLastPacketID = packet.packetID
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
            if !keepAllSinceStart, ringSamples.count > ringCapacity {
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
        keepAllSinceStart = false
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
        keepAllSinceStart = false
        lock.unlock()
    }

    /// Clears capture state only. The BLE link stays up so the next press is heard.
    @MainActor
    func stop() {
        lock.lock()
        recording = false
        recordingSamples = []
        ringSamples = []
        keepAllSinceStart = false
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
