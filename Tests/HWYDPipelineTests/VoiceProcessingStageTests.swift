import XCTest
import HWYDCore
@testable import HWYDPipeline

/// The voice post-processing stage over doubles of its ports: no model, no keychain, no store.
final class VoiceProcessingStageTests: XCTestCase {
    private func axis(_ index: Int) -> [Float] { var vector = [Float](repeating: 0, count: 256); vector[index] = 1; return vector }
    private func windows(_ speaker: UUID, _ vector: [Float], from: Int, to: Int) -> [VoiceWindow] {
        stride(from: from, to: to, by: 10).map { VoiceWindow(speakerID: speaker, start: Double($0), end: Double($0) + 10, vector: vector) }
    }

    func testAVoiceHoldingAKnownPersonGetsAProposalNamingThemAndTheResultCarriesNoVector() async throws {
        let folder = try StageFolder()
        var known = VoicePerson(name: "Boris")
        known.enrollmentRequestedAt = Date()
        let vault = InMemorySecretVault()
        let prints = VoicePrints(vault: vault)
        try prints.add(axis(2), person: known.id, channel: .remote, recordingID: UUID(), speakerID: UUID())
        known.enrolledChannels = [.remote]
        let people = InMemoryVoicePeople([known])

        // One voice of the call: 300 s of one person, then 60 s of Boris, at the same level.
        let voice = Speaker(label: "Voix 1", source: .system), brief = Speaker(label: "Voix 2", source: .system)
        let chunk = try folder.chunk("system.caf", source: .system, seconds: 400, level: 0.1)
        let segments = [TranscriptSegment(start: 0, end: 300, speakerID: voice.id, source: .system, text: "a"),
                        TranscriptSegment(start: 300, end: 360, speakerID: voice.id, source: .system, text: "b"),
                        TranscriptSegment(start: 380, end: 383, speakerID: brief.id, source: .system, text: "c")]
        var result = TranscriptionResult(request: TranscriptionRequest(recordingID: UUID(), chunks: [chunk], diarize: true), segments: segments)
        result.speakers = [voice, brief]

        let output = await VoiceProcessingStage.run(result, windows: windows(voice.id, axis(1), from: 0, to: 300) + windows(voice.id, axis(2), from: 300, to: 360),
                                                    people: people, audio: folder.audio, prints: prints, directory: folder.root, audioOverrides: [:]).result

        let proposal = try XCTUnwrap(output.splitProposals?.first)
        XCTAssertEqual(proposal.speakerID, voice.id)
        XCTAssertEqual(proposal.segmentIDs, [segments[1].id])
        XCTAssertEqual(proposal.proposedIdentity?.personID, known.id)
        // The larger part is not Boris, and 3 s out of 363 s is too brief to ask for a name.
        XCTAssertNil(output.speakers?[0].proposedIdentity)
        XCTAssertEqual(output.speakers?.map(\.automatic), [nil, .minor])
        XCTAssertEqual(output.voiceProcessingEngine, VoicePostProcessor.engine)
        XCTAssertNil(output.identityWarning)

        // What goes back to the app holds decisions only: no list of numbers long enough to be a vector.
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(output))
        func arrays(_ value: Any) -> [[Any]] {
            if let array = value as? [Any] { return [array] + array.flatMap(arrays) }
            if let dictionary = value as? [String: Any] { return dictionary.values.flatMap(arrays) }
            return []
        }
        XCTAssertFalse(arrays(object).contains { $0.count >= 16 && $0.allSatisfy { $0 is NSNumber } })
    }

    func testWithoutEmbeddingsTheStageOnlyAppliesTheRulesThatNeedNone() async throws {
        let folder = try StageFolder()
        let me = Speaker(label: "Voix 1", source: .mic), echo = Speaker(label: "Voix 2", source: .mic), remote = Speaker(label: "Voix 3", source: .system)
        var result = TranscriptionResult(request: TranscriptionRequest(recordingID: UUID(), chunks: [], diarize: true), segments: [
            TranscriptSegment(start: 0, end: 100, speakerID: remote.id, source: .system, text: "a"),
            TranscriptSegment(start: 200, end: 300, speakerID: me.id, source: .mic, text: "b"),
            TranscriptSegment(start: 10, end: 20, speakerID: echo.id, source: .mic, text: "c")])
        result.speakers = [me, echo, remote]

        let output = await VoiceProcessingStage.run(result, windows: [], people: InMemoryVoicePeople([]), audio: folder.audio, prints: nil,
                                                    directory: folder.root, audioOverrides: [:]).result

        XCTAssertEqual(output.speakers?.map(\.automatic), [nil, .echo, nil])
        XCTAssertNil(output.splitProposals)
        XCTAssertNil(output.absorbedSpeakers)
    }
}
