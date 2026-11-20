import XCTest
@testable import HWYDCore

final class VoiceCoherenceTests: XCTestCase {
    private let voice = UUID(), other = UUID()
    private func segment(_ start: Double, _ end: Double, _ speaker: UUID? = nil, _ source: AudioSource = .system) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, speakerID: speaker ?? voice, source: source, text: "")
    }

    func testUsableSegmentsDropShortAndOverlappingSpeech() {
        let segments = [segment(20, 25), segment(0, 0.4), segment(10, 15), segment(14, 16, other), segment(14, 16, other, .mic)]
        XCTAssertEqual(VoiceCoherence.usableSegments(of: voice, in: segments).map(\.start), [20])
    }

    func testUnionMergesOverlappingSpansAndOverlapMeasuresCoverage() {
        let spans = VoiceCoherence.union([.init(start: 5, end: 9), .init(start: 0, end: 6), .init(start: 20, end: 22), .init(start: 3, end: 3)])
        XCTAssertEqual(spans, [.init(start: 0, end: 9), .init(start: 20, end: 22)])
        XCTAssertEqual(VoiceCoherence.seconds([.init(start: 0, end: 6), .init(start: 5, end: 9)]), 9)
        XCTAssertEqual(VoiceCoherence.overlap(.init(start: 8, end: 21), with: spans), 2)
    }

    func testSpreadSamplesTheWholeVoiceAndKeepsAShortOneWhole() {
        let short = [VoiceCoherence.Span(start: 0, end: 40)]
        XCTAssertEqual(VoiceCoherence.spread(short), short)
        // 600 s of speech in two stretches: six slices of 10 s, one every 100 s of speech.
        let sample = VoiceCoherence.spread([.init(start: 0, end: 300), .init(start: 1000, end: 1300)])
        XCTAssertEqual(sample.map(\.start), [0, 100, 200, 1000, 1100, 1200])
        XCTAssertEqual(VoiceCoherence.seconds(sample), 60, accuracy: 1e-9)
    }

    func testSplitSeparatesTwoDistinctVoicesAndReportsTheirSimilarity() throws {
        // Two directions about 0.4 apart in cosine, each with small variations.
        let a: [Float] = [1, 0, 0, 0], b: [Float] = [0.4, 0.92, 0, 0]
        let vectors = [a, a, b, [0.98, 0.05, 0.1, 0], b, [0.35, 0.93, 0, 0.1]]
        let split = try XCTUnwrap(VoiceCoherence.split(vectors, weights: Array(repeating: 10, count: vectors.count)))
        XCTAssertEqual(split.assignment[0], split.assignment[1])
        XCTAssertEqual(split.assignment[0], split.assignment[3])
        XCTAssertEqual(split.assignment[2], split.assignment[4])
        XCTAssertEqual(split.assignment[2], split.assignment[5])
        XCTAssertNotEqual(split.assignment[0], split.assignment[2])
        XCTAssertLessThan(split.between, 0.5)
    }

    func testSplitOfOneVoiceKeepsCloseCentroids() throws {
        let vectors: [[Float]] = [[1, 0.02, 0], [1, -0.02, 0], [1, 0, 0.03], [1, 0, -0.03]]
        let split = try XCTUnwrap(VoiceCoherence.split(vectors, weights: [10, 10, 10, 10]))
        XCTAssertGreaterThan(split.between, 0.99)
        XCTAssertNil(VoiceCoherence.split([[1, 0]], weights: [10]))
    }

    func testCrossTrackOverlapCountsSharedTimeOnceAndNamesTheOverlappedVoices() {
        let mic = UUID()
        let segments = [segment(0, 10, mic, .mic), segment(2, 6, voice), segment(4, 8, other), segment(20, 30, voice)]
        let overlap = VoiceCoherence.crossTrackOverlap(of: mic, in: segments)
        XCTAssertEqual(overlap.share, 0.6, accuracy: 1e-9)
        XCTAssertEqual(overlap.byVoice, [voice: 4, other: 4])
        XCTAssertEqual(VoiceCoherence.crossTrackOverlap(of: UUID(), in: segments).share, 0)
    }
}
