import XCTest
@testable import HWYDCore

/// Notices: which ones wait for the user, how actions are described, and the recording double.
@MainActor final class UserNotifierTests: XCTestCase {
    func testInformationLeavesAndDecisionsWait() {
        XCTAssertFalse(UserNotice.info("Saved").waitsForUser)
        XCTAssertFalse(UserNotice.error("Failed").waitsForUser)
        XCTAssertTrue(UserNotice.info("Read me", sticky: true).waitsForUser)
        XCTAssertTrue(UserNotice.error("Failed", actions: [.perform("Retry") {}]).waitsForUser)
        // An optional offer such as an undo leaves on its own.
        XCTAssertFalse(UserNotice.success("Merged", actions: [.perform("Undo") {}], optional: true).waitsForUser)
    }

    func testActionsNameADestinationOrAnEffect() {
        let id = UUID()
        let show = UserNotice.Action.navigate("Show", to: .session(id, .summary))
        guard case .navigate(let intent) = show.effect else { return XCTFail("Expected a navigation") }
        XCTAssertEqual(intent, .session(id, .summary))
        var ran = false
        let retry = UserNotice.Action.perform("Retry") { ran = true }
        guard case .perform(let run) = retry.effect else { return XCTFail("Expected an effect") }
        run()
        XCTAssertTrue(ran)
        XCTAssertNotEqual(show.id, retry.id)
    }

    func testRecordingNotifierKeepsNoticesInOrder() {
        let notifier = RecordingNotifier()
        notifier.notify(.info("First"))
        notifier.notify(.error("Second"))
        XCTAssertEqual(notifier.messages, ["First", "Second"])
        XCTAssertEqual(notifier.notices.map(\.style), [.info, .error])
        notifier.clear()
        XCTAssertTrue(notifier.notices.isEmpty)
    }
}
