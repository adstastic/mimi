import Foundation
import MimiAEC

final class EchoCancellationStream {
    private let processor: OpaquePointer?
    private var renderRemainder: [Float] = []
    private var captureRemainder: [Float] = []
    private var renderSampleRate: Int32?
    private var captureSampleRate: Int32?
    private(set) var hasRenderReference = false

    init() {
        processor = MimiAECCreate()
    }

    deinit {
        MimiAECDestroy(processor)
    }

    @discardableResult
    func processRender(_ samples: [Float], sampleRate: Int32) -> Bool {
        guard processor != nil, let frameSize = frameSize(for: sampleRate) else { return false }
        if renderSampleRate != sampleRate {
            renderRemainder.removeAll(keepingCapacity: true)
            renderSampleRate = sampleRate
        }

        renderRemainder.append(contentsOf: samples)
        var processed = false
        while renderRemainder.count >= frameSize {
            var frame = Array(renderRemainder.prefix(frameSize))
            renderRemainder.removeFirst(frameSize)
            let succeeded = frame.withUnsafeMutableBufferPointer {
                MimiAECProcessRender(processor, $0.baseAddress, $0.count, sampleRate)
            }
            processed = processed || succeeded
        }
        hasRenderReference = hasRenderReference || processed
        return processed
    }

    func processCapture(_ samples: [Float], sampleRate: Int32) -> [Float] {
        guard processor != nil, hasRenderReference, let frameSize = frameSize(for: sampleRate) else {
            captureRemainder.removeAll(keepingCapacity: true)
            return samples
        }
        if captureSampleRate != sampleRate {
            captureRemainder.removeAll(keepingCapacity: true)
            captureSampleRate = sampleRate
        }

        captureRemainder.append(contentsOf: samples)
        var output: [Float] = []
        output.reserveCapacity(captureRemainder.count - captureRemainder.count % frameSize)
        while captureRemainder.count >= frameSize {
            var frame = Array(captureRemainder.prefix(frameSize))
            captureRemainder.removeFirst(frameSize)
            let original = frame
            let succeeded = frame.withUnsafeMutableBufferPointer {
                MimiAECProcessCapture(processor, $0.baseAddress, $0.count, sampleRate, 0)
            }
            output.append(contentsOf: succeeded ? frame : original)
        }
        return output
    }

    func flushCapture() -> [Float] {
        guard !captureRemainder.isEmpty else { return [] }
        guard processor != nil,
              hasRenderReference,
              let sampleRate = captureSampleRate,
              let frameSize = frameSize(for: sampleRate) else {
            defer { captureRemainder.removeAll(keepingCapacity: true) }
            return captureRemainder
        }

        let sampleCount = captureRemainder.count
        var frame = captureRemainder
        frame.append(contentsOf: repeatElement(0, count: frameSize - frame.count))
        captureRemainder.removeAll(keepingCapacity: true)
        let original = frame
        let succeeded = frame.withUnsafeMutableBufferPointer {
            MimiAECProcessCapture(processor, $0.baseAddress, $0.count, sampleRate, 0)
        }
        return Array((succeeded ? frame : original).prefix(sampleCount))
    }

    private func frameSize(for sampleRate: Int32) -> Int? {
        let size = Int(MimiAECFrameSize(sampleRate))
        return size > 0 ? size : nil
    }
}
