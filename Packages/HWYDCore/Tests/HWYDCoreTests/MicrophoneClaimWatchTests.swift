import XCTest
@testable import HWYDCore

final class MicrophoneClaimWatchTests: XCTestCase {
    func testAppAlreadyReadingInputAtStartDoesNotRestart() {
        var watch = MicrophoneClaimWatch(readers: [42])
        XCTAssertFalse(watch.poll(readers: [42], now: 0))
        XCTAssertFalse(watch.poll(readers: [42], now: 30))
    }

    func testNewcomerRestartsOnceAfterSettling() {
        var watch = MicrophoneClaimWatch(readers: [])
        XCTAssertFalse(watch.poll(readers: [42], now: 10))
        XCTAssertFalse(watch.poll(readers: [42], now: 11), "The meeting app is still setting up its audio graph")
        XCTAssertTrue(watch.poll(readers: [42], now: 11.5))
        XCTAssertFalse(watch.poll(readers: [42], now: 12))
        XCTAssertFalse(watch.poll(readers: [42], now: 60))
    }

    func testNewcomerThatLeavesBeforeSettlingStillRestarts() {
        // Its voice processing may have left the device reconfigured.
        var watch = MicrophoneClaimWatch(readers: [])
        XCTAssertFalse(watch.poll(readers: [42], now: 0))
        XCTAssertTrue(watch.poll(readers: [], now: 2))
    }

    func testInputToggledOnMuteIsRateLimited() {
        var watch = MicrophoneClaimWatch(readers: [])
        _ = watch.poll(readers: [42], now: 0)
        XCTAssertTrue(watch.poll(readers: [42], now: 2))
        _ = watch.poll(readers: [], now: 3)
        XCTAssertFalse(watch.poll(readers: [42], now: 4))
        XCTAssertFalse(watch.poll(readers: [42], now: 6), "Less than ten seconds after the previous restart")
        XCTAssertTrue(watch.poll(readers: [42], now: 12))
    }

    func testResetDropsPendingRestart() {
        var watch = MicrophoneClaimWatch(readers: [])
        _ = watch.poll(readers: [42], now: 0)
        watch.reset(readers: [42])
        XCTAssertFalse(watch.poll(readers: [42], now: 5))
    }
}
