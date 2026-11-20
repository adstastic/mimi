import Foundation
import XCTest
@testable import Mimi
@testable import MimiSpeech

@MainActor
final class FluidSpeechProTests: XCTestCase {
    func testDownloadRetryReusesCompletedFilesAndRejectsShortDownloads() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = "Decoder.mlmodelc/analytics/coremldata.bin"
        let second = "Decoder.mlmodelc/coremldata.bin"
        let secondDestination = directory.appending(path: second)
        for (path, bytes) in FluidSpeechProBackend.assets where path != first && path != second {
            let destination = directory.appending(path: path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let file = try FileHandle(forWritingTo: destination)
            try file.truncate(atOffset: UInt64(bytes))
            try file.close()
        }
        try Data([0]).write(to: secondDestination)

        var progress: Progress?
        var attempts: [String] = []
        var downloadsStarted = 0
        func install(secondSize: Int) async throws {
            try await FluidSpeechProBackend.installMissingAssets(in: directory, onDownloadProgress: { update in
                progress = update
                if update != nil { downloadsStarted += 1 }
            }) { url, downloadProgress, bytes, install in
                attempts.append(url.path)
                let isFirst = url.path.hasSuffix("/\(first)")
                let progress = try XCTUnwrap(progress)
                XCTAssertEqual(progress.totalUnitCount - progress.completedUnitCount, isFirst ? 243 + 491 : 491)
                let temporaryFile = directory.appending(path: UUID().uuidString)
                try Data(repeating: 7, count: isFirst ? 243 : secondSize).write(to: temporaryFile)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                try install(temporaryFile, response)
                downloadProgress.completedUnitCount += bytes
            }
        }

        do {
            try await install(secondSize: 490)
            XCTFail("Accepted a short download")
        } catch {
            XCTAssertNil(progress)
        }
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: first)), Data(repeating: 7, count: 243))
        XCTAssertEqual(try Data(contentsOf: secondDestination), Data([0]))

        try await install(secondSize: 491)
        XCTAssertEqual(try Data(contentsOf: secondDestination), Data(repeating: 7, count: 491))
        try await install(secondSize: 0)
        let basePath = "/FluidVoice-Labs/fluid-speech-pro-coreml/resolve/3b9d38a93d606f84011e5a0a669b7ea146375a22"
        XCTAssertEqual(attempts, ["\(basePath)/\(first)", "\(basePath)/\(second)", "\(basePath)/\(second)"])
        XCTAssertEqual(downloadsStarted, 2)
        XCTAssertNil(progress)
    }

    func testRejectsNonFileAudioBeforePreparingModel() async throws {
        let service = ASRService()
        do {
            _ = try await service.transcribe(audioURL: URL(string: "https://example.invalid/audio.wav")!, backend: .fluidSpeechPro)
            XCTFail("Accepted a remote recording URL")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .unsupportedURL)
        }
    }

    func testRealModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let cache = environment["MIMI_FLUID_SPEECH_PRO_CACHE"] else {
            throw XCTSkip("Set MIMI_FLUID_SPEECH_PRO_CACHE to test real Fluid Speech Pro weights")
        }
        let audio = try XCTUnwrap(environment["MIMI_FLUID_SPEECH_PRO_AUDIO"], "Set MIMI_FLUID_SPEECH_PRO_AUDIO to a local audio file")
        let cacheDirectory = URL(fileURLWithPath: cache, isDirectory: true)
        let incompleteFile = FluidSpeechProBackend.assets.first { path, bytes in
            !FluidSpeechProBackend.hasExpectedSize(bytes, at: cacheDirectory.appending(path: path))
        }
        if let incompleteFile, environment["MIMI_FLUID_SPEECH_PRO_ALLOW_DOWNLOAD"] != "1" {
            XCTFail("Incomplete model cache: \(incompleteFile.path). Set MIMI_FLUID_SPEECH_PRO_ALLOW_DOWNLOAD=1 to download missing files.")
            return
        }

        var progress: Progress?
        var downloadsStarted = 0
        let backend = FluidSpeechProBackend(cacheDirectory: cacheDirectory) { update in
            progress = update
            if update != nil { downloadsStarted += 1 }
        }
        let service = ASRService(fluidBackend: backend)
        async let first: Void = service.prepare(backend: .fluidSpeechPro)
        async let second: Void = service.prepare(backend: .fluidSpeechPro)
        _ = try await (first, second)
        XCTAssertEqual(downloadsStarted, incompleteFile == nil ? 0 : 1)
        XCTAssertNil(progress)
        let expected = environment["MIMI_FLUID_SPEECH_PRO_EXPECTED_TEXT"] ?? "The blue bicycle is beside the kitchen window."
        for _ in 0..<2 {
            let text = try await service.transcribe(audioURL: URL(fileURLWithPath: audio), backend: .fluidSpeechPro)
            XCTAssertEqual(text, expected)
        }
    }
}
