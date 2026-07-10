@preconcurrency import AVFoundation
import XCTest
@testable import Mimi

final class AudioCaptureTests: XCTestCase {
    func testMultichannelInputUsesChannelCarryingAudio() throws {
        let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | 20)
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: layoutTag))
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            interleaved: false,
            channelLayout: layout
        ))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        input.frameLength = 4
        let expected: [Float] = [0.25, -0.5, 0.75, -1]
        let activeChannel = try XCTUnwrap(input.floatChannelData?[3])
        expected.withUnsafeBufferPointer { samples in
            activeChannel.update(from: samples.baseAddress!, count: samples.count)
        }

        let capture = AudioCapture()
        var forwarded: AVAudioPCMBuffer?
        capture.beginRecording(bufferHandler: { forwarded = $0 }, replayPreRollToHandler: false)
        capture.handle(buffer: input)
        let audioURL = try capture.finishRecording()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let forwardedBuffer = try XCTUnwrap(forwarded)
        XCTAssertEqual(forwardedBuffer.format.channelCount, 1)
        XCTAssertEqual(Array(UnsafeBufferPointer(
            start: try XCTUnwrap(forwardedBuffer.floatChannelData?[0]),
            count: Int(forwardedBuffer.frameLength)
        )), expected)

        let file = try AVAudioFile(forReading: audioURL)
        let recorded = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: recorded)
        XCTAssertEqual(Array(UnsafeBufferPointer(
            start: try XCTUnwrap(recorded.floatChannelData?[0]),
            count: Int(recorded.frameLength)
        )), expected)
    }
}
