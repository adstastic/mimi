import XCTest
@testable import MimiSpeech

final class VoiceprintPrototypeTests: XCTestCase {
    func testProfileUsesSpeakerEmbeddingDistanceThreshold() throws {
        let profile = try VoiceprintPrototype.makeProfile(
            from: [
                [1, 0, 0],
                [0.98, 0.20, 0]
            ],
            thresholdOverride: 0.30
        )

        XCTAssertEqual(profile.version, 2)
        XCTAssertEqual(profile.sampleCount, 2)
        XCTAssertLessThan(VoiceprintPrototype.cosineDistance([1, 0, 0], profile.embedding), profile.threshold)
        XCTAssertGreaterThan(VoiceprintPrototype.cosineDistance([0, 1, 0], profile.embedding), profile.threshold)
    }
}
