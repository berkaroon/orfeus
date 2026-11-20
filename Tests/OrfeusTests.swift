import AudioCore
import XCTest

final class OrfeusTests: XCTestCase {
    func testAttenuationNeverBoostsOrAcceptsInvalidInput() {
        XCTAssertEqual(Gain(2), .unity)
        XCTAssertEqual(Gain(.infinity), .unity)
        XCTAssertEqual(Gain(-0.2).value, 0)
        XCTAssertEqual(Gain(0.25).value, 0.25)
    }
}
