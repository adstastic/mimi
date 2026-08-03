import XCTest
import MimiAEC
@testable import Mimi

final class EchoCancellationTests: XCTestCase {
    func testCaptureFailsOpenUntilSpeakerReferenceIsAvailable() {
        let stream = EchoCancellationStream()
        let capture = [Float](repeating: 0.125, count: 1_024)

        XCTAssertEqual(stream.processCapture(capture, sampleRate: 16_000), capture)
    }

    func testCaptureIsReframedWithoutInventingOrDroppingSamples() {
        let stream = EchoCancellationStream()
        _ = stream.processRender([Float](repeating: 0, count: 480), sampleRate: 48_000)

        XCTAssertEqual(
            stream.processCapture([Float](repeating: 0.125, count: 1_024), sampleRate: 16_000).count,
            960
        )
        XCTAssertEqual(
            stream.processCapture([Float](repeating: 0.125, count: 96), sampleRate: 16_000).count,
            160
        )
    }

    func testAEC3AttenuatesCorrelatedSpeakerEcho() throws {
        let sampleRate: Int32 = 16_000
        let frameSize = Int(MimiAECFrameSize(sampleRate))
        XCTAssertEqual(frameSize, 160)

        guard let processor = MimiAECCreate() else {
            XCTFail("Could not create AEC3 processor")
            return
        }
        defer { MimiAECDestroy(processor) }

        var generator = DeterministicNoise()
        var inputEnergy: Float = 0
        var outputEnergy: Float = 0

        for frameIndex in 0..<500 {
            var render = (0..<frameSize).map { _ in generator.next() }
            var capture = render.map { $0 * 0.55 }

            XCTAssertTrue(MimiAECProcessRender(processor, &render, render.count, sampleRate))
            if frameIndex >= 400 {
                inputEnergy += capture.reduce(0) { $0 + $1 * $1 }
            }
            XCTAssertTrue(MimiAECProcessCapture(processor, &capture, capture.count, sampleRate, 0))
            if frameIndex >= 400 {
                outputEnergy += capture.reduce(0) { $0 + $1 * $1 }
            }
        }

        XCTAssertLessThan(outputEnergy, inputEnergy * 0.25)
    }
}

private struct DeterministicNoise {
    private var state: UInt32 = 0x1234_5678

    mutating func next() -> Float {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Float(Int32(bitPattern: state)) / Float(Int32.max) * 0.25
    }
}
