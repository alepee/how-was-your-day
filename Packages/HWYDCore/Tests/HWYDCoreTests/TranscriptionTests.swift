import XCTest
@testable import HWYDCore

final class TranscriptionTests: XCTestCase, @unchecked Sendable {
    func testResultsPreserveLatestNotesAndInvalidateSummary() throws {
        var recording = Recording(title: "Test", notes: "Notes pendant le traitement", summary: "Ancienne synthèse")
        recording.audioChunks = [.init(source: .mic, relativePath: "mic.caf", start: 300, duration: 5)]
        let request = TranscriptionRequest(recordingID: recording.id, chunks: recording.audioChunks)
        let segment = TranscriptSegment(start: 301, end: 302, speakerID: nil, source: .mic, text: "Bonjour")
        try recording.applyTranscription(.init(request: request, segments: [segment]))
        XCTAssertEqual(recording.notes, "Notes pendant le traitement")
        XCTAssertEqual(recording.transcriptVersion, 1)
        XCTAssertEqual(recording.transcriptState, .ready)
        XCTAssertNil(recording.summary)
        XCTAssertTrue(recording.speakers.isEmpty)
        XCTAssertNil(recording.segments.first?.speakerID)
    }
    func testRejectsResultFromDifferentAudio() throws {
        var recording = Recording(title: "Test")
        let request = TranscriptionRequest(recordingID: recording.id, chunks: [.init(source: .mic, relativePath: "old.caf", start: 0, duration: 1)])
        XCTAssertThrowsError(try recording.applyTranscription(.init(request: request, segments: [])))
        XCTAssertEqual(recording.transcriptVersion, 0)
    }
    func testOldPayloadWithoutWordsStillDecodes() throws {
        let segment = TranscriptSegment(start: 0, end: 1, speakerID: nil, source: .mic, text: "Bonjour")
        let data = try JSONEncoder().encode(segment)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        XCTAssertNil(decoded.words)
    }
    func testPipelineMergesTracksBySessionTimeWithoutInventingSpeakers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SessionStore(directory: directory)
        let request = TranscriptionRequest(recordingID: UUID(), chunks: [
            .init(source: .mic, relativePath: "mic.caf", start: 300, duration: 5),
            .init(source: .system, relativePath: "system.caf", start: 0, duration: 5)])
        let result = try await TranscriptionPipeline.run(request, store: store, recognizer: FakeRecognizer())
        XCTAssertEqual(result.segments.map(\.start), [1, 301])
        XCTAssertEqual(result.segments.map(\.source), [.system, .mic])
        XCTAssertTrue(result.segments.allSatisfy { $0.speakerID == nil })
    }
}
private struct FakeRecognizer: SpeechRecognizing {
    func transcribe(file: URL, chunk: AudioChunk, locale: String) async throws -> [TranscriptSegment] {
        [.init(start: chunk.start + 1, end: chunk.start + 2, speakerID: nil, source: chunk.source, text: "Bonjour")]
    }
}
