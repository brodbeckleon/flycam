import XCTest
@testable import DirectorCore

final class SkeletonTests: XCTestCase {
    func testFrameworkLoads() {
        XCTAssertFalse(DirectorCore.version.isEmpty)
    }
}
