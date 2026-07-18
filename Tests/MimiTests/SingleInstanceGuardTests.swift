import XCTest
@testable import Mimi

final class SingleInstanceGuardTests: XCTestCase {
    func testSecondGuardForSameLockIsNotPrimary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimiTests.\(UUID().uuidString)", isDirectory: true)
        let lockURL = directory.appendingPathComponent("single-instance.lock")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let first = SingleInstanceGuard(lockURL: lockURL)
            let second = SingleInstanceGuard(lockURL: lockURL)

            XCTAssertTrue(first.isPrimary)
            XCTAssertFalse(second.isPrimary)

            withExtendedLifetime((first, second)) {}
        }

        XCTAssertTrue(SingleInstanceGuard(lockURL: lockURL).isPrimary)
    }
}
