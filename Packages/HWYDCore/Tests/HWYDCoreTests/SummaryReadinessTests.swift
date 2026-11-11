import XCTest
@testable import HWYDCore

final class SummaryReadinessTests: XCTestCase, @unchecked Sendable {
    private func session(_ speakers: [Speaker], text: String = "Bonjour") -> Recording {
        let segment = TranscriptSegment(start: 0, end: 1, speakerID: speakers.first?.id, source: .mic, text: text)
        return Recording(title: "Test", speakers: speakers, segments: [segment])
    }
    func testReadyOnceEveryKeptVoiceIsConfirmed() throws {
        let first = Speaker(label: "Voix 1"), echo = Speaker(label: "Voix 2")
        var item = session([first, echo])
        XCTAssertFalse(item.isReadyForSummary)
        try item.renameSpeaker(first.id, to: "Alice")
        XCTAssertFalse(item.isReadyForSummary)
        try item.setSpeakerIgnored(echo.id, true)
        XCTAssertTrue(item.isReadyForSummary)
    }
    func testProposedIdentityIsNotEnough() {
        var speaker = Speaker(label: "Alice")
        speaker.proposedIdentity = VoiceMatch(personID: UUID(), score: 0.9, margin: nil, channel: .mic)
        XCTAssertFalse(session([speaker]).isReadyForSummary)
    }
    func testNotReadyWithSummaryEmptyTranscriptRecordingOrDemo() {
        let named = Speaker(label: "Alice", confirmed: true)
        XCTAssertTrue(session([named]).isReadyForSummary)
        var summarized = session([named]); summarized.summary = "Déjà faite"
        XCTAssertFalse(summarized.isReadyForSummary)
        XCTAssertFalse(session([named], text: "  ").isReadyForSummary)
        var recording = session([named]); recording.state = .recording
        XCTAssertFalse(recording.isReadyForSummary)
        var pending = session([named]); pending.transcriptState = .pending
        XCTAssertFalse(pending.isReadyForSummary)
        var demo = session([named]); demo.isDemo = true
        XCTAssertFalse(demo.isReadyForSummary)
    }
    func testSessionWithoutSeparatedVoicesIsReady() {
        XCTAssertTrue(session([]).isReadyForSummary)
    }
}
