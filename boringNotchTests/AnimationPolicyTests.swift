import Defaults
import XCTest
@testable import boringNotch

final class AnimationPolicyTests: XCTestCase {
    private var originalEnabled = true
    private var originalSpeed = 1.0

    override func setUp() {
        super.setUp()
        originalEnabled = Defaults[.enableOpeningAnimation]
        originalSpeed = Defaults[.animationSpeedMultiplier]
    }

    override func tearDown() {
        Defaults[.enableOpeningAnimation] = originalEnabled
        Defaults[.animationSpeedMultiplier] = originalSpeed
        super.tearDown()
    }

    func testSpeedClampsToSupportedRange() {
        XCTAssertEqual(StandardAnimations.clampedSpeed(-1), 0.25)
        XCTAssertEqual(StandardAnimations.clampedSpeed(0.25), 0.25)
        XCTAssertEqual(StandardAnimations.clampedSpeed(3), 3)
        XCTAssertEqual(StandardAnimations.clampedSpeed(10), 3)
    }

    func testOpeningAndClosingResponsesScalePredictably() {
        for speed in [0.25, 0.5, 1.0, 2.0, 3.0] {
            Defaults[.animationSpeedMultiplier] = speed
            XCTAssertEqual(StandardAnimations.openingResponse, 0.42 / speed, accuracy: 0.000_001)
            XCTAssertEqual(StandardAnimations.closingResponse, 0.45 / speed, accuracy: 0.000_001)
        }
    }

    func testDisablingPolicyRemovesBoundaryAnimations() {
        Defaults[.enableOpeningAnimation] = false
        XCTAssertNil(StandardAnimations.opening)
        XCTAssertNil(StandardAnimations.closing)

        Defaults[.enableOpeningAnimation] = true
        XCTAssertNotNil(StandardAnimations.opening)
        XCTAssertNotNil(StandardAnimations.closing)
    }
}
