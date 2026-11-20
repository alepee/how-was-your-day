import XCTest
import HWYDCore
@testable import HWYDPipeline

final class DiarizationStageTests: XCTestCase {
    private func segment(_ source: AudioSource, _ words: [(String, Double, Double)]) -> TranscriptSegment {
        var segment = TranscriptSegment(start: words.first!.1, end: words.last!.2, speakerID: nil, source: source, text: words.map(\.0).joined())
        segment.words = words.map { TranscriptWord(text: $0.0, start: $0.1, end: $0.2) }
        return segment
    }

    func testRunAlignsTheTurnsOfTheDiarizerItIsGiven() async throws {
        let folder = try StageFolder()
        let mic = try folder.chunk("mic.caf", source: .mic, seconds: 2, level: 0.1)
        let system = try folder.chunk("system.caf", source: .system, seconds: 2, level: 0.2)
        let request = TranscriptionRequest(recordingID: UUID(), chunks: [mic, system], diarize: true)
        let result = TranscriptionResult(request: request, segments: [
            segment(.mic, [("Bonjour", 0, 0.5), (" à", 0.5, 0.8), (" tous", 1.2, 1.8)]),
            segment(.system, [("Hello", 0.2, 0.9)])
        ])
        let diarizer = ScriptedDiarizer([
            .mic: [SpeakerTurn(cluster: "a", source: .mic, start: 0, end: 1), SpeakerTurn(cluster: "b", source: .mic, start: 1, end: 2)],
            .system: [SpeakerTurn(cluster: "a", source: .system, start: 0, end: 2)]
        ])
        let cleaned = folder.root.appendingPathComponent("mic.caf")
        let diagnostic = folder.root.appendingPathComponent("alignment.json")

        let output = try await DiarizationStage.run(result, audio: folder.audio, diarizer: diarizer, workingDirectory: folder.root,
                                                    diagnosticURL: diagnostic, microphoneOverride: cleaned)

        // Two voices on the microphone, one on the call: a cluster name is local to its track.
        XCTAssertEqual(output.speakers?.map(\.source), [.mic, .mic, .system])
        XCTAssertEqual(output.segments.map(\.text), ["Bonjour à", "Hello", "tous"])
        XCTAssertEqual(Set(output.segments.compactMap(\.speakerID)).count, 3)
        XCTAssertEqual(output.diarizationEngine, "fluidaudio-0.17.7-community-1-exclusive")

        // The echo-cancelled microphone is read as given; the call audio is assembled for the diarizer.
        let requests = await diarizer.requests
        XCTAssertEqual(requests.map(\.source), [.mic, .system])
        XCTAssertEqual(requests[0].file, cleaned)
        XCTAssertEqual(requests[1].file.lastPathComponent, "system.caf")
        XCTAssertNotEqual(requests[1].file, try folder.audio.url(for: system))
        XCTAssertTrue(requests.allSatisfy(\.existed))
        // The assembled audio is disposable: nothing of it remains.
        XCTAssertFalse(FileManager.default.fileExists(atPath: requests[1].file.deletingLastPathComponent().path))

        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: diagnostic)) as? [String: Any]
        XCTAssertEqual(Set(written?.keys.map { $0 } ?? []), ["schema", "segments", "turns"])
        XCTAssertEqual((written?["turns"] as? [[String: Any]])?.count, 3)
    }

    func testRunSkipsATrackWithoutTranscript() async throws {
        let folder = try StageFolder()
        let mic = try folder.chunk("mic.caf", source: .mic, seconds: 1, level: 0.1)
        let system = try folder.chunk("system.caf", source: .system, seconds: 1, level: 0.2)
        let result = TranscriptionResult(request: TranscriptionRequest(recordingID: UUID(), chunks: [mic, system], diarize: true),
                                         segments: [segment(.system, [("Hello", 0.2, 0.9)])])
        let diarizer = ScriptedDiarizer([.system: [SpeakerTurn(cluster: "a", source: .system, start: 0, end: 1)]])

        let output = try await DiarizationStage.run(result, audio: folder.audio, diarizer: diarizer, workingDirectory: folder.root)

        let requests = await diarizer.requests
        XCTAssertEqual(requests.map(\.source), [.system])
        XCTAssertEqual(output.speakers?.count, 1)
    }
}
