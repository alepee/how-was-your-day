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
    func testCorrectionKeepsTheSummaryAndMarksItStale() throws {
        var item = DemoContent.recordings()[0]; item.isDemo = false
        let unknown = try XCTUnwrap(item.speakers.first { !$0.confirmed })
        XCTAssertFalse(item.summaryIsStale)
        let summary = item.summary
        try item.renameSpeaker(unknown.id, to: "Léa")
        XCTAssertEqual(item.summary, summary)
        XCTAssertTrue(item.summaryIsStale)
        // A summary exists: the session is never ready for an automatic one again.
        XCTAssertFalse(item.isReadyForSummary)
        let exported = try SessionExporter.document(item)["summary"] as? [String: Any]
        XCTAssertEqual(exported?["status"] as? String, "stale")
        XCTAssertEqual(exported?["markdown"] as? String, summary)
    }
    func testSummaryWithoutProvenanceIsNotStale() throws {
        var item = session([Speaker(label: "Alice", confirmed: true)]); item.summary = "Synthèse"
        try item.renameSpeaker(item.speakers[0].id, to: "Alice B.")
        XCTAssertFalse(item.summaryIsStale)
    }
}
