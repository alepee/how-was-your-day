import XCTest
@testable import HWYDCore

final class VoicePostProcessingTests: XCTestCase {
    // Three directions far apart, as three people are.
    private let anna: [Float] = [1, 0, 0, 0], boris: [Float] = [0.3, 0.95, 0, 0], carla: [Float] = [0.2, 0.1, 0.97, 0]
    private func segment(_ start: Double, _ end: Double, _ speaker: UUID, _ source: AudioSource = .system) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, speakerID: speaker, source: source, text: "x")
    }
    /// One 10 s window every 10 s over `range`, all with the same vector.
    private func windows(_ speaker: UUID, _ vector: [Float], _ range: ClosedRange<Int>) -> [VoiceWindow] {
        stride(from: range.lowerBound, to: range.upperBound, by: 10).map { VoiceWindow(speakerID: speaker, start: Double($0), end: Double($0) + 10, vector: vector) }
    }
    private func recording(_ speakers: [Speaker], _ segments: [TranscriptSegment]) -> Recording {
        Recording(title: "Test", speakers: speakers, segments: segments)
    }
    private let normalLevel: ([VoiceCoherence.Span], AudioSource) -> Double? = { _, _ in -28 }

    func testMicrophoneVoiceHeardOnlyWhileTheCallSpeaksIsAnEcho() {
        let me = Speaker(label: "Voix 1", source: .mic), echo = Speaker(label: "Voix 2", source: .mic), remote = Speaker(label: "Voix 3", source: .system)
        var processor = VoicePostProcessor(recording: recording([me, echo, remote], [
            segment(0, 100, remote.id), segment(200, 300, me.id, .mic), segment(10, 20, echo.id, .mic), segment(150, 152, echo.id, .mic),
        ]), windows: [])
        processor.markEchoes()
        let result = processor.recording
        XCTAssertEqual(result.speakers.map(\.automatic), [nil, .echo, nil])
        XCTAssertEqual(result.speakers.map(\.ignored), [false, true, false])
        XCTAssertEqual(processor.measures[echo.id]?.crossTrackOverlap ?? 0, 10.0 / 12, accuracy: 1e-9)
        // A remote voice is never an echo, whatever the microphone says meanwhile.
        XCTAssertEqual(processor.measures[remote.id]?.crossTrackOverlap, 0)
    }

    func testVoiceHoldingTwoPeopleGetsAProposalNamingTheSmallerPart() throws {
        let voice = Speaker(label: "Voix 1", source: .system), other = Speaker(label: "Voix 2", source: .system)
        let segments = [segment(0, 300, voice.id), segment(300, 360, voice.id), segment(360, 600, voice.id), segment(700, 900, other.id)]
        var processor = VoicePostProcessor(recording: recording([voice, other], segments),
                                           windows: windows(voice.id, anna, 0...300) + windows(voice.id, boris, 300...360) + windows(voice.id, anna, 360...600) + windows(other.id, carla, 700...900))
        processor.detect(level: normalLevel)
        let proposal = try XCTUnwrap(processor.recording.pendingSplitProposals.first)
        XCTAssertEqual(proposal.speakerID, voice.id)
        XCTAssertEqual(proposal.segmentIDs, [segments[1].id])
        XCTAssertLessThan(proposal.similarity, 0.5)
        XCTAssertNil(proposal.mergeInto)
        XCTAssertEqual(processor.measures[voice.id]?.split?.smallSeconds, 60)
        // Nothing moved yet, and the voice is compared with memory by its larger part only.
        XCTAssertEqual(processor.recording.segments.map(\.speakerID), [voice.id, voice.id, voice.id, other.id])
        let rows = processor.identificationCandidates
        XCTAssertEqual(rows.map(\.key), [.voice(voice.id), .voice(other.id), .proposal(proposal.id)])
        XCTAssertGreaterThan(VoiceCoherence.cosine(rows[0].vector, anna), 0.999)
        XCTAssertGreaterThan(VoiceCoherence.cosine(rows[2].vector, boris), 0.999)
    }

    func testNoProposalForAShortSecondGroupAQuietOneOrOneVoice() {
        let voice = Speaker(label: "Voix 1", source: .system)
        func proposals(_ windows: [VoiceWindow], level: @escaping ([VoiceCoherence.Span], AudioSource) -> Double?) -> Int {
            var processor = VoicePostProcessor(recording: recording([voice], [segment(0, 300, voice.id), segment(300, 360, voice.id)]), windows: windows)
            processor.detect(level: level)
            return processor.recording.pendingSplitProposals.count
        }
        // 20 s of another voice: an interjection, not a participant hidden in this voice.
        XCTAssertEqual(proposals(windows(voice.id, anna, 0...300) + windows(voice.id, boris, 300...320), level: normalLevel), 0)
        // Same person further from the microphone: the second group is far quieter.
        let two = windows(voice.id, anna, 0...300) + windows(voice.id, boris, 300...360)
        XCTAssertEqual(proposals(two, level: { spans, _ in spans.first?.start == 300 ? -47 : -27 }), 0)
        // A whole session recorded very low: no level to trust.
        XCTAssertEqual(proposals(two, level: { _, _ in -50 }), 0)
        XCTAssertEqual(proposals(two, level: { _, _ in nil }), 0)
        XCTAssertEqual(proposals(windows(voice.id, anna, 0...360), level: normalLevel), 0)
        // Windows where the voice is not nearly alone are too noisy to accuse it.
        let brief = stride(from: 300, to: 360, by: 5).map { VoiceWindow(speakerID: voice.id, start: Double($0), end: Double($0) + 5, vector: boris) }
        XCTAssertEqual(proposals(windows(voice.id, anna, 0...300) + brief, level: normalLevel), 0)
        XCTAssertEqual(proposals(two, level: normalLevel), 1)
    }

    func testShorterVoiceJoinsTheLongerOneItSoundsLikeAndCanLeaveAgain() throws {
        let long = Speaker(label: "Voix 1", source: .system), short = Speaker(label: "Voix 2", source: .system)
        let distinct = Speaker(label: "Voix 3", source: .system), mic = Speaker(label: "Voix 4", source: .mic)
        let segments = [segment(0, 300, long.id), segment(300, 340, short.id), segment(400, 500, distinct.id), segment(600, 700, mic.id, .mic)]
        var processor = VoicePostProcessor(recording: recording([long, short, distinct, mic], segments),
                                           windows: windows(long.id, anna, 0...300) + windows(short.id, [0.98, 0.1, 0.05, 0], 300...340)
                                               + windows(distinct.id, boris, 400...500) + windows(mic.id, anna, 600...700))
        processor.detect(level: normalLevel)
        var result = processor.recording
        // Same voice on the other track stays apart: channels differ.
        XCTAssertEqual(result.speakers.map(\.id), [long.id, distinct.id, mic.id])
        XCTAssertEqual(result.segments[1].speakerID, long.id)
        XCTAssertEqual(result.absorbedSpeakers?.map(\.automatic), [.merged])
        XCTAssertEqual(processor.measures[short.id]?.nearestLonger, long.id)
        try result.separateSpeaker(short.id, from: long.id)
        XCTAssertEqual(result.segments[1].speakerID, short.id)
        XCTAssertNil(result.speakers.first { $0.id == short.id }?.automatic)
    }

    func testSmallerPartOfAProposalKnowsTheVoiceItSoundsLike() throws {
        let voice = Speaker(label: "Voix 1", source: .system), boris = Speaker(label: "Voix 2", source: .system)
        let segments = [segment(0, 300, voice.id), segment(300, 360, voice.id), segment(400, 800, boris.id)]
        var processor = VoicePostProcessor(recording: recording([voice, boris], segments),
                                           windows: windows(voice.id, anna, 0...300) + windows(voice.id, self.boris, 300...360) + windows(boris.id, self.boris, 400...800))
        processor.detect(level: normalLevel)
        var result = processor.recording
        let proposal = try XCTUnwrap(result.pendingSplitProposals.first)
        XCTAssertEqual(proposal.mergeInto, boris.id)
        // The voice keeps its place while it waits for the answer.
        XCTAssertEqual(result.speakers.map(\.id), [voice.id, boris.id])
        XCTAssertEqual(try result.acceptSplit(proposal.id), boris.id)
        XCTAssertEqual(result.segments.map(\.speakerID), [voice.id, boris.id, boris.id])
        XCTAssertTrue(result.pendingSplitProposals.isEmpty)
    }

    func testAcceptedSplitNamesTheNewVoiceAndDismissedOneLeavesEverythingInPlace() throws {
        let voice = Speaker(label: "Voix 1", source: .system)
        let segments = [segment(0, 300, voice.id), segment(300, 360, voice.id)]
        var processor = VoicePostProcessor(recording: recording([voice], segments), windows: windows(voice.id, anna, 0...300) + windows(voice.id, boris, 300...360))
        processor.detect(level: normalLevel)
        let person = VoicePerson(name: "Boris")
        let proposalID = try XCTUnwrap(processor.recording.pendingSplitProposals.first).id
        processor.applyIdentities([.proposal(proposalID): VoiceMatch(personID: person.id, score: 0.9, margin: 0.3, channel: .remote)])
        processor.classify()
        var accepted = processor.recording
        let created = try accepted.acceptSplit(proposalID, people: [person])
        XCTAssertEqual(accepted.segments.map(\.speakerID), [voice.id, created])
        let named = try XCTUnwrap(accepted.speakers.first { $0.id == created })
        XCTAssertEqual(named.label, "Boris")
        XCTAssertEqual(named.proposedIdentity?.personID, person.id)
        XCTAssertFalse(named.confirmed)
        XCTAssertNil(accepted.splitProposals)

        var dismissed = processor.recording
        try dismissed.dismissSplit(proposalID)
        XCTAssertEqual(dismissed.segments.map(\.speakerID), [voice.id, voice.id])
        XCTAssertNil(dismissed.splitProposals)
        XCTAssertThrowsError(try dismissed.acceptSplit(proposalID))
    }

    func testProposalGoesStaleWhenItsPassagesLeaveTheVoice() throws {
        let voice = Speaker(label: "Voix 1", source: .system), other = Speaker(label: "Voix 2", source: .system)
        let segments = [segment(0, 300, voice.id), segment(300, 360, voice.id), segment(400, 800, other.id)]
        var item = recording([voice, other], segments)
        item.splitProposals = [VoiceSplitProposal(speakerID: voice.id, segmentIDs: [segments[1].id], similarity: 0.4)]
        XCTAssertEqual(item.pendingSplitProposals.count, 1)
        try item.assignSpeaker(other.id, to: segments[1].id)
        XCTAssertTrue(item.pendingSplitProposals.isEmpty)
    }

    func testBriefUnrecognisedVoiceIsMinorAndTheOthersAreNumberedAgain() throws {
        let main = Speaker(label: "Voix 1", source: .system), brief = Speaker(label: "Voix 2", source: .system)
        let thanks = Speaker(label: "Voix 3", source: .system), second = Speaker(label: "Voix 4", source: .system)
        let segments = [segment(0, 2000, main.id), segment(2000, 2012, brief.id), segment(2020, 2045, thanks.id), segment(2100, 3100, second.id)]
        var processor = VoicePostProcessor(recording: recording([main, brief, thanks, second], segments), windows: windows(thanks.id, carla, 2020...2040))
        processor.detect(level: normalLevel)
        let person = VoicePerson(name: "Romain")
        XCTAssertEqual(processor.identificationCandidates.map(\.key), [.voice(thanks.id)])
        processor.applyIdentities([.voice(thanks.id): VoiceMatch(personID: person.id, score: 0.9, margin: 0.3, channel: .remote)])
        processor.classify()
        var result = processor.recording
        // 25 s out of 3037 s: brief, yet recognised, so it stays a voice to confirm.
        XCTAssertEqual(result.speakers.map(\.automatic), [nil, .minor, nil, nil])
        XCTAssertEqual(result.speakers.map(\.label), ["Voix 1", "Autre voix", "Voix 2", "Voix 3"])
        XCTAssertEqual(result.voiceOverview.map(\.state), [.unidentified, .minor, .proposed, .unidentified])
        XCTAssertEqual(result.participantNames, "3 voix à nommer")
        try result.restoreMinorVoice(brief.id)
        XCTAssertEqual(result.speakers[1].label, "Voix 5")
        XCTAssertNil(result.speakers[1].automatic)
    }

    func testBriefVoiceOfAShortSessionIsNotMinor() {
        let main = Speaker(label: "Voix 1", source: .system), brief = Speaker(label: "Voix 2", source: .system)
        var processor = VoicePostProcessor(recording: recording([main, brief], [segment(0, 500, main.id), segment(500, 512, brief.id)]), windows: [])
        processor.classify()
        // 12 s is over 1 % of a ten-minute exchange: that voice took part.
        XCTAssertEqual(processor.recording.speakers.map(\.automatic), [nil, nil])
    }

    func testUserDecisionsClearTheAutomaticOne() throws {
        var echo = Speaker(label: "Voix 1", source: .mic); echo.ignored = true; echo.automatic = .echo
        var minor = Speaker(label: "Autre voix", source: .system); minor.automatic = .minor
        var item = recording([echo, minor], [segment(0, 5, echo.id, .mic), segment(10, 15, minor.id)])
        XCTAssertTrue(item.voicesResolved)
        try item.setSpeakerIgnored(echo.id, false)
        XCTAssertNil(item.speakers[0].automatic)
        try item.renameSpeaker(minor.id, to: "Dana")
        XCTAssertNil(item.speakers[1].automatic)
        XCTAssertTrue(item.speakers[1].confirmed)
    }

    func testStoredSessionRoundTripsDecisionsAndOlderOnesStillDecode() throws {
        var voice = Speaker(label: "Voix 1", source: .mic); voice.automatic = .minor
        var item = recording([voice], [segment(0, 5, voice.id, .mic)])
        item.splitProposals = [VoiceSplitProposal(speakerID: voice.id, segmentIDs: [item.segments[0].id], similarity: 0.5)]
        let data = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(Recording.self, from: data), item)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["splitProposals"] = nil
        object["speakers"] = [["id": voice.id.uuidString, "label": "Voix 1", "confirmed": false, "source": "mic"]]
        let old = try JSONDecoder().decode(Recording.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.speakers[0].automatic)
        XCTAssertTrue(old.pendingSplitProposals.isEmpty)
    }
}
