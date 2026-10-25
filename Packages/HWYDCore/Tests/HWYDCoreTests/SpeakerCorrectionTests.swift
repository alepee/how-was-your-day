import XCTest
@testable import HWYDCore

final class SpeakerCorrectionTests: XCTestCase, @unchecked Sendable {
    func testCorrectionPreservesOtherSegmentsWordsAndSpeakerProfiles() throws {
        let first = Speaker(label: "Voix 1"), second = Speaker(label: "Voix 2")
        var segment = TranscriptSegment(start: 1, end: 2, speakerID: first.id, source: .mic, text: "Bonjour")
        segment.words = [.init(text: "Bonjour", start: 1, end: 2)]
        let other = TranscriptSegment(start: 3, end: 4, speakerID: first.id, source: .mic, text: "Suite")
        var item = Recording(title: "Test", notes: "Notes conservées", speakers: [first, second], segments: [segment, other], summary: "Ancienne synthèse")
        try item.assignSpeaker(second.id, to: segment.id)
        XCTAssertEqual(item.transcriptVersion, 2)
        XCTAssertEqual(item.segments[0].speakerID, second.id)
        XCTAssertEqual(item.segments[0].words, segment.words)
        XCTAssertEqual(item.segments[1], other)
        XCTAssertEqual(item.speakers, [first, second])
        XCTAssertEqual(item.notes, "Notes conservées")
        XCTAssertNil(item.summary)
        try item.assignSpeaker(second.id, to: segment.id)
        XCTAssertEqual(item.transcriptVersion, 2)
        try item.assignSpeaker(nil, to: segment.id)
        XCTAssertNil(item.segments[0].speakerID)
        XCTAssertEqual(item.transcriptVersion, 3)
    }
    func testRejectsUnknownSpeakerAndOtherTrackWithoutMutation() throws {
        let remote = Speaker(label: "Distant", source: .system)
        let segment = TranscriptSegment(start: 0, end: 1, speakerID: nil, source: .mic, text: "Test")
        var item = Recording(title: "Test", speakers: [remote], segments: [segment], summary: "À garder")
        let original = item
        XCTAssertThrowsError(try item.assignSpeaker(UUID(), to: segment.id))
        XCTAssertThrowsError(try item.assignSpeaker(remote.id, to: segment.id))
        XCTAssertThrowsError(try item.assignSpeaker(nil, to: UUID()))
        XCTAssertEqual(item, original)
    }
    func testCorrectionHistoryPersistsAcrossReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try SessionStore(directory: folder)
        let speaker = Speaker(label: "Voix 1")
        let segment = TranscriptSegment(start: 0, end: 1, speakerID: nil, source: .mic, text: "Bonjour")
        var item = try await store.save(Recording(title: "Test", speakers: [speaker], segments: [segment]))
        try item.assignSpeaker(speaker.id, to: segment.id)
        _ = try await store.save(item)
        let history = try await SessionStore(directory: folder).versions(for: item.id)
        XCTAssertEqual(history.map(\.transcriptVersion), [1, 2])
        XCTAssertNil(history[0].segments[0].speakerID)
        XCTAssertEqual(history[1].segments[0].speakerID, speaker.id)
    }
}
