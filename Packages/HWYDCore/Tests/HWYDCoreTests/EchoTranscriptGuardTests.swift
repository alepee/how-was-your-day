import XCTest
@testable import HWYDCore

final class EchoTranscriptGuardTests: XCTestCase {
    func testKnownSpeakerStillGetsReviewHintWithoutTextOrIdentityChanges() {
        let id = UUID()
        let mic = TranscriptSegment(start: 12, end: 15, speakerID: id, source: .mic,
                                    text: "On va préparer la migration des données demain matin")
        let system = TranscriptSegment(start: 10, end: 14, speakerID: UUID(), source: .system,
                                       text: "Très bien. On va préparer la migration des données demain matin. Voilà.")
        let output = EchoTranscriptGuard.annotate([mic, system])
        XCTAssertEqual(output[0].echoSuspect, true)
        XCTAssertEqual(output[0].text, mic.text)
        XCTAssertEqual(output[0].speakerID, id)
        XCTAssertEqual(output[0].id, mic.id)
        XCTAssertEqual(output[1].echoSuspect, false)
        XCTAssertEqual(output.count, 2)
    }

    func testApproximateASRAndSystemBoundary() {
        let source = UUID()
        let segments = [
            TranscriptSegment(start: 20, end: 24, speakerID: nil, source: .mic, text: "Nous allons organiser le partage des informations avec toute l équipe demain"),
            TranscriptSegment(start: 19, end: 21, speakerID: source, source: .system, text: "Nous allons organiser le partage"),
            TranscriptSegment(start: 21, end: 24, speakerID: source, source: .system, text: "des documents avec toute l'équipe demain")
        ]
        XCTAssertEqual(EchoTranscriptGuard.annotate(segments)[0].echoSuspect, true)
    }

    func testShortWordsLocalSpeechAndDistantRepetitionStayUntouched() {
        let text = "Nous préparons la migration des données demain matin"
        let system = TranscriptSegment(start: 10, end: 15, speakerID: nil, source: .system, text: text + " oui deux MCP")
        let short = TranscriptSegment(start: 12, end: 13, speakerID: nil, source: .mic, text: "deux")
        let local = TranscriptSegment(start: 12, end: 15, speakerID: nil, source: .mic, text: "Je pense que nous devons d'abord revoir les accès des utilisateurs")
        let later = TranscriptSegment(start: 30, end: 34, speakerID: nil, source: .mic, text: text)
        XCTAssertTrue(EchoTranscriptGuard.annotate([short, local, later, system]).allSatisfy { $0.echoSuspect == false })
    }

    func testLegacySegmentsDecodeAsNotEvaluated() throws {
        let segment = TranscriptSegment(start: 0, end: 1, speakerID: nil, source: .mic, text: "Bonjour")
        let data = try JSONEncoder().encode(segment)
        XCTAssertNil(try JSONDecoder().decode(TranscriptSegment.self, from: data).echoSuspect)
    }

    func testLocalDuplicateWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["HWYD_ECHO_REVIEW_RECORDING"] else {
            throw XCTSkip("Local review fixture is opt-in and never bundled.")
        }
        let url = URL(fileURLWithPath: path)
        var recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url))
        let originalID = recording.id
        recording.id = UUID()
        recording.title = "Echo review copy"
        recording.segments = EchoTranscriptGuard.annotate(recording.segments)
        let output = url.deletingLastPathComponent().appendingPathComponent("annotated-recording.json")
        try JSONEncoder().encode(recording).write(to: output, options: .atomic)
        XCTAssertNotEqual(recording.id, originalID)
        print("Review copy: \(recording.segments.filter { $0.echoSuspect == true }.count) suspected microphone repetitions out of \(recording.segments.count) segments")
    }
}
