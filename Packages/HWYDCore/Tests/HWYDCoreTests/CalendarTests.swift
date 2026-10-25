import XCTest
@testable import HWYDCore

final class CalendarTests: XCTestCase {
    func testMeetingLinksAreRestrictedToKnownHTTPSHosts() {
        XCTAssertEqual(MeetingRules.meetingURL(in: "Lieu : https://meet.google.com/abc-defg-hij")?.host, "meet.google.com")
        XCTAssertEqual(MeetingRules.meetingURL(in: "<a href=\"https://eu.zoom.us/j/123\">Join</a>")?.host, "eu.zoom.us")
        XCTAssertNil(MeetingRules.meetingURL(in: "https://meet.google.com.evil.test/x"))
        XCTAssertNil(MeetingRules.meetingURL(in: "http://meet.google.com/abc"))
        XCTAssertNil(MeetingRules.meetingURL(in: "file:///tmp/x"))
    }
    func testExclusionsUseWordsAndIgnoreCaseAndAccents() {
        XCTAssertTrue(MeetingRules.isExcluded(title: "RDV medical", keywords: "RH, médical"))
        XCTAssertTrue(MeetingRules.isExcluded(title: "Point RH", keywords: "RH"))
        XCTAssertFalse(MeetingRules.isExcluded(title: "Architecture", keywords: "RH"))
        XCTAssertFalse(MeetingRules.isExcluded(title: "Standup", keywords: " , "))
    }
    func testRemindersNeverReplayPastTimes() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(MeetingRules.reminderDate(start: now.addingTimeInterval(600), minutes: 5, now: now), now.addingTimeInterval(300))
        XCTAssertNil(MeetingRules.reminderDate(start: now.addingTimeInterval(60), minutes: 5, now: now))
        XCTAssertEqual(MeetingRules.reminderDate(start: now.addingTimeInterval(60), minutes: 0, now: now), now.addingTimeInterval(60))
    }
    func testBackwardCompatibilityAndCalendarRoundtrip() throws {
        var recording = Recording(title: "Meeting")
        let encoder = JSONEncoder()
        let old = try encoder.encode(recording)
        XCTAssertNil(try JSONDecoder().decode(Recording.self, from: old).calendarContext)
        recording.calendarContext = CalendarContext(id: "occurrence", title: "Réunion", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600), calendarTitle: "Travail", participants: [.init(name: "Test", email: "test@example.com")])
        XCTAssertEqual(try JSONDecoder().decode(Recording.self, from: encoder.encode(recording)), recording)
        XCTAssertFalse(recording.consentAnnounced)
        XCTAssertTrue(recording.speakers.isEmpty)
    }
}
