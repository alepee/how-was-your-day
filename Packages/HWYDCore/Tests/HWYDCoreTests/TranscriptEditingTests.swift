import XCTest
@testable import HWYDCore

final class TranscriptEditingTests: XCTestCase, @unchecked Sendable {
    private func passage() -> TranscriptSegment {
        var value = TranscriptSegment(start: 1, end: 4, speakerID: UUID(), source: .mic, text: "Oui. Bonjour Antoine.")
        value.words = [.init(text: "Oui.", start: 1, end: 1.5), .init(text: " Bonjour", start: 2, end: 3), .init(text: " Antoine.", start: 3, end: 4)]
        return value
    }
    func testSplitPreservesWordsIdentityAndOtherSegments() throws {
        let original = passage()
        let other = TranscriptSegment(start: 5, end: 6, speakerID: nil, source: .system, text: "Suite")
        var recording = Recording(title: "Test", notes: "Notes", segments: [original, other], summary: "Synthèse")
        try recording.splitSegment(original.id, beforeWord: 1)
        XCTAssertEqual(recording.segments.count, 3)
        XCTAssertEqual(recording.segments[0].id, original.id)
        XCTAssertNotEqual(recording.segments[1].id, original.id)
        XCTAssertEqual(recording.segments[0].text, "Oui.")
        XCTAssertEqual(recording.segments[1].text, "Bonjour Antoine.")
        XCTAssertEqual(recording.segments[0].end, 1.5)
        XCTAssertEqual(recording.segments[1].start, 2)
        XCTAssertEqual(Array(recording.segments.prefix(2)).flatMap { $0.words ?? [] }, original.words)
        XCTAssertTrue(recording.segments.prefix(2).allSatisfy { $0.speakerID == original.speakerID && $0.source == original.source })
        XCTAssertEqual(recording.segments[2], other)
        XCTAssertEqual(recording.notes, "Notes")
        XCTAssertEqual(recording.transcriptVersion, 2)
        XCTAssertNil(recording.summary)
    }
    func testInvalidOrIncompleteTimingCannotInventBoundary() throws {
        var segment = passage()
        XCTAssertEqual(segment.splitIndices, [1, 2])
        segment.words![1].start = 1.4
        XCTAssertEqual(segment.splitIndices, [2])
        segment.words![1].start = .nan
        XCTAssertTrue(segment.splitIndices.isEmpty)
        segment = passage(); segment.words!.removeLast()
        XCTAssertTrue(segment.splitIndices.isEmpty)
        segment = passage(); segment.words![0].start = -1
        XCTAssertTrue(segment.splitIndices.isEmpty)
        segment = passage(); segment.words = nil
        XCTAssertTrue(segment.splitIndices.isEmpty)
        var recording = Recording(title: "Test", segments: [passage()])
        let original = recording
        for index in [-1, 0, 3, 10] {
            XCTAssertThrowsError(try recording.splitSegment(recording.segments[0].id, beforeWord: index))
            XCTAssertEqual(recording, original)
        }
    }
    func testSplitAndPartialReassignmentSurviveReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try SessionStore(directory: folder)
        var segment = passage()
        let first = Speaker(label: "Romain"), second = Speaker(label: "Antoine")
        segment.speakerID = first.id
        var recording = try await store.save(Recording(title: "Test", speakers: [first, second], segments: [segment]))
        try recording.splitSegment(segment.id, beforeWord: 1)
        recording = try await store.save(recording)
        try recording.assignSpeaker(second.id, to: recording.segments[1].id)
        recording = try await store.save(recording)
        let versions = try await SessionStore(directory: folder).versions(for: recording.id)
        XCTAssertEqual(versions.map(\.transcriptVersion), [1, 2, 3])
        XCTAssertEqual(versions[0].segments, [segment])
        XCTAssertEqual(versions[2].segments.map(\.speakerID), [first.id, second.id])
    }
}
