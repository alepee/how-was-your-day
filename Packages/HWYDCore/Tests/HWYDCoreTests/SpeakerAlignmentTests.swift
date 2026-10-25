import XCTest
@testable import HWYDCore

final class SpeakerAlignmentTests: XCTestCase {
    private func phrase(source: AudioSource = .mic) -> TranscriptSegment {
        var segment = TranscriptSegment(start: 0, end: 3, speakerID: nil, source: source, text: "Bonjour à tous")
        segment.words = [.init(text: "Bonjour", start: 0, end: 1), .init(text: " à", start: 1, end: 2), .init(text: " tous", start: 2, end: 3)]
        return segment
    }
    func testSplitsAtSpeakerChangeAndPreservesWords() {
        let result = SpeakerAlignment.apply(segments: [phrase()], turns: [.init(cluster: "a", source: .mic, start: 0, end: 1.6), .init(cluster: "b", source: .mic, start: 1.6, end: 3)])
        XCTAssertEqual(result.segments.map(\.text), ["Bonjour à", "tous"])
        XCTAssertEqual(result.speakers.count, 2)
        XCTAssertTrue(result.speakers.allSatisfy { !$0.confirmed })
        XCTAssertEqual(result.segments.flatMap { $0.words ?? [] }.count, 3)
    }
    func testTiesAndUncoveredWordsStayUnknown() {
        let result = SpeakerAlignment.apply(segments: [phrase()], turns: [.init(cluster: "a", source: .mic, start: 0, end: 0.5), .init(cluster: "b", source: .mic, start: 0.5, end: 1)])
        XCTAssertTrue(result.speakers.isEmpty)
        XCTAssertTrue(result.segments.allSatisfy { $0.speakerID == nil })
    }
    func testSameClusterNameOnDifferentTracksDoesNotMergePeople() {
        let result = SpeakerAlignment.apply(segments: [phrase(), phrase(source: .system)], turns: [.init(cluster: "0", source: .mic, start: 0, end: 3), .init(cluster: "0", source: .system, start: 0, end: 3)])
        XCTAssertEqual(result.speakers.count, 2)
        XCTAssertNotEqual(result.segments[0].speakerID, result.segments[1].speakerID)
    }
    func testMissingWordTimingNeverDropsTextOrInventsAttribution() {
        var segment = phrase(); segment.words = nil
        let result = SpeakerAlignment.apply(segments: [segment], turns: [.init(cluster: "a", source: .mic, start: 0, end: 3)])
        XCTAssertEqual(result.segments[0].text, segment.text)
        XCTAssertNil(result.segments[0].speakerID)
        segment.words = [.init(text: "Bonjour", start: 0, end: 1)]
        XCTAssertEqual(SpeakerAlignment.apply(segments: [segment], turns: []).segments[0].text, segment.text)
    }
    func testDuplicateIntervalsDoNotBiasOverlapVote() {
        let result = SpeakerAlignment.apply(segments: [phrase()], turns: [.init(cluster: "a", source: .mic, start: 0, end: 0.4), .init(cluster: "a", source: .mic, start: 0, end: 0.4), .init(cluster: "b", source: .mic, start: 0.4, end: 3)])
        XCTAssertEqual(result.speakers.count, 1)
        XCTAssertEqual(result.segments.count, 1)
    }
}
