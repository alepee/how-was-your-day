import XCTest
@testable import HWYDCore

final class MicrophoneClaimWatchTests: XCTestCase {
    func testNoOtherReaderAtStartDoesNotRestart() {
        var watch = MicrophoneClaimWatch(readers: [], now: 0)
        XCTAssertFalse(watch.poll(readers: [], now: 2))
        XCTAssertFalse(watch.poll(readers: [], now: 30))
    }

    func testAppAlreadyReadingInputAtStartRestartsOnceAfterSettling() {
        // Creating the capture's aggregate may make a meeting app set up its voice processing again, same process.
        var watch = MicrophoneClaimWatch(readers: [42], now: 0)
        XCTAssertFalse(watch.poll(readers: [42], now: 1), "The meeting app is still setting up its audio graph")
        XCTAssertTrue(watch.poll(readers: [42], now: 1.5))
        watch.reset(readers: [42])
        XCTAssertFalse(watch.poll(readers: [42], now: 2))
        XCTAssertFalse(watch.poll(readers: [42], now: 60))
    }

    func testAppThatStopsReadingBeforeSettlingStillRestarts() {
        // Its voice processing may have left the device reconfigured.
        var watch = MicrophoneClaimWatch(readers: [42], now: 0)
        XCTAssertTrue(watch.poll(readers: [], now: 2))
    }

    func testNewcomerRestartsOnceAfterSettling() {
        var watch = MicrophoneClaimWatch(readers: [], now: 0)
        XCTAssertFalse(watch.poll(readers: [42], now: 10))
        XCTAssertFalse(watch.poll(readers: [42], now: 11), "The meeting app is still setting up its audio graph")
        XCTAssertTrue(watch.poll(readers: [42], now: 11.5))
        XCTAssertFalse(watch.poll(readers: [42], now: 12))
        XCTAssertFalse(watch.poll(readers: [42], now: 60))
    }

    func testNewcomerThatLeavesBeforeSettlingStillRestarts() {
        // Its voice processing may have left the device reconfigured.
        var watch = MicrophoneClaimWatch(readers: [], now: 0)
        XCTAssertFalse(watch.poll(readers: [42], now: 0))
        XCTAssertTrue(watch.poll(readers: [], now: 2))
    }

    func testInputToggledOnMuteIsRateLimited() {
        var watch = MicrophoneClaimWatch(readers: [], now: 0)
        _ = watch.poll(readers: [42], now: 0)
        XCTAssertTrue(watch.poll(readers: [42], now: 2))
        _ = watch.poll(readers: [], now: 3)
        XCTAssertFalse(watch.poll(readers: [42], now: 4))
        XCTAssertFalse(watch.poll(readers: [42], now: 6), "Less than ten seconds after the previous restart")
        XCTAssertTrue(watch.poll(readers: [42], now: 12))
    }

    func testResetDropsPendingRestart() {
        var watch = MicrophoneClaimWatch(readers: [], now: 0)
        _ = watch.poll(readers: [42], now: 0)
        watch.reset(readers: [42])
        XCTAssertFalse(watch.poll(readers: [42], now: 5))
    }

    func testNewGraphWithAppReadingInputRestartsOnce() {
        // A microphone switch or an output change builds a new aggregate, which the meeting app may react to.
        var watch = MicrophoneClaimWatch(readers: [42], now: 0)
        XCTAssertTrue(watch.poll(readers: [42], now: 1.5))
        watch.reset(readers: [42])
        watch.graphBuilt(readers: [42], now: 30)
        XCTAssertFalse(watch.poll(readers: [42], now: 31))
        XCTAssertTrue(watch.poll(readers: [42], now: 31.5))
    }

    func testNewGraphWithoutOtherReaderDropsPendingRestart() {
        var watch = MicrophoneClaimWatch(readers: [], now: 0)
        _ = watch.poll(readers: [42], now: 0)
        watch.graphBuilt(readers: [], now: 1)
        XCTAssertFalse(watch.poll(readers: [], now: 5))
    }
}
