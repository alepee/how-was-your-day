import XCTest
@testable import HWYDCore

final class VoiceReviewTests: XCTestCase {
    func testOverviewReportsStateAndSpeechPerVoice() {
        var proposed = Speaker(label: "Camille", source: .system)
        proposed.proposedIdentity = VoiceMatch(personID: UUID(), score: 0.8, margin: 0.2, channel: .remote)
        let named = Speaker(label: "Vous", confirmed: true), unknown = Speaker(label: "Voix 3")
        let item = Recording(title: "Test", speakers: [named, proposed, unknown], segments: [
            .init(start: 0, end: 2, speakerID: named.id, source: .mic, text: "a"),
            .init(start: 3, end: 4.5, speakerID: named.id, source: .mic, text: "b"),
            .init(start: 5, end: 6, speakerID: proposed.id, source: .system, text: "c"),
            .init(start: 7, end: 8, speakerID: nil, source: .mic, text: "d")])
        let overview = item.voiceOverview
        XCTAssertEqual(overview.map(\.state), [.confirmed, .proposed, .unidentified])
        XCTAssertEqual(overview[0].segmentCount, 2)
        XCTAssertEqual(overview[0].speechDuration, 3.5)
        XCTAssertEqual(overview[0].spans, [.init(start: 0, end: 2), .init(start: 3, end: 4.5)])
        XCTAssertEqual(overview[2].segmentCount, 0)
    }

    func testSameTrackMergeMovesSegmentsAndKeepsNamedIdentity() throws {
        let named = Speaker(label: "Léa", confirmed: true), duplicate = Speaker(label: "Voix 2")
        let other = Speaker(label: "Voix 3", source: .system)
        let segments: [TranscriptSegment] = [
            .init(start: 0, end: 1, speakerID: named.id, source: .mic, text: "a"),
            .init(start: 1, end: 2, speakerID: duplicate.id, source: .mic, text: "b"),
            .init(start: 2, end: 3, speakerID: other.id, source: .system, text: "c")]
        var item = Recording(title: "Test", speakers: [named, duplicate, other], segments: segments, summary: "old")
        // Dropping the named voice onto the unnamed one keeps the name on the survivor.
        try item.mergeSpeaker(named.id, into: duplicate.id)
        XCTAssertEqual(item.speakers.map(\.id), [duplicate.id, other.id])
        XCTAssertEqual(item.speakers[0].label, "Léa")
        XCTAssertTrue(item.speakers[0].confirmed)
        XCTAssertEqual(item.segments.map(\.speakerID), [duplicate.id, duplicate.id, other.id])
        XCTAssertEqual(item.segments.map(\.text), ["a", "b", "c"])
        XCTAssertEqual(item.transcriptVersion, 2)
        XCTAssertEqual(item.summary, "old")
    }

    func testCrossTrackMergeSharesNameWithoutMovingSegments() throws {
        let person = VoicePerson(name: "Camille")
        var remote = Speaker(label: "Voix 1", source: .system)
        let room = Speaker(label: "Voix 2")
        var item = Recording(title: "Test", speakers: [remote, room], segments: [
            .init(start: 0, end: 1, speakerID: remote.id, source: .system, text: "a"),
            .init(start: 1, end: 2, speakerID: room.id, source: .mic, text: "b")])
        let unchanged = item
        XCTAssertThrowsError(try item.mergeSpeaker(room.id, into: remote.id)) { XCTAssertEqual($0 as? VoiceReviewError, .unnamedMerge) }
        XCTAssertEqual(item, unchanged)
        try item.linkSpeaker(remote.id, to: person)
        remote = item.speakers[0]
        try item.mergeSpeaker(room.id, into: remote.id)
        XCTAssertEqual(item.speakers.count, 2)
        XCTAssertEqual(item.speakers.map(\.label), ["Camille", "Camille"])
        XCTAssertEqual(item.speakers.map(\.personID), [person.id, person.id])
        XCTAssertEqual(item.segments.map(\.speakerID), [remote.id, room.id])
        XCTAssertEqual(item.participants.count, 1)
    }

    func testLinkRefusesOpposedPersonAndSelfMerge() {
        let speaker = Speaker(label: "Voix 1")
        var item = Recording(title: "Test", speakers: [speaker])
        let original = item
        XCTAssertThrowsError(try item.linkSpeaker(speaker.id, to: VoicePerson(name: "Exclu", opposed: true)))
        XCTAssertThrowsError(try item.mergeSpeaker(speaker.id, into: speaker.id))
        XCTAssertEqual(item, original)
    }

    func testPlaylistMergesOverlapsAndMapsElapsedTimeBack() {
        let playlist = VoicePlaylist(spans: [.init(start: 10, end: 12), .init(start: 2, end: 4), .init(start: 3, end: 5)], gap: 0.5)
        XCTAssertEqual(playlist.entries, [.init(from: 2, to: 5, at: 0), .init(from: 10, to: 12, at: 3.5)])
        XCTAssertEqual(playlist.length, 5.5)
        XCTAssertEqual(playlist.recordingTime(atElapsed: 1), 3)
        XCTAssertEqual(playlist.recordingTime(atElapsed: 3.2), 10)
        XCTAssertEqual(playlist.recordingTime(atElapsed: 4), 10.5)
        XCTAssertEqual(playlist.recordingTime(atElapsed: 9), 12)
        XCTAssertEqual(VoicePlaylist(spans: []).length, 0)
    }

    func testActiveSegmentsCoverOverlappingTracks() {
        let a = TranscriptSegment(start: 0, end: 5, speakerID: nil, source: .mic, text: "a")
        let b = TranscriptSegment(start: 4, end: 8, speakerID: nil, source: .system, text: "b")
        let item = Recording(title: "Test", segments: [a, b])
        XCTAssertEqual(item.segmentIDs(at: 4.5), [a.id, b.id])
        XCTAssertEqual(item.segmentIDs(at: 5), [b.id])
        XCTAssertEqual(item.segmentIDs(at: 9), [])
    }

    func testIgnoredVoiceIsHiddenEverywhereAndReversible() throws {
        let me = Speaker(label: "Vous", confirmed: true), echo = Speaker(label: "Voix 2")
        let segments: [TranscriptSegment] = [
            .init(start: 0, end: 1, speakerID: me.id, source: .mic, text: "bonjour"),
            .init(start: 1, end: 2, speakerID: echo.id, source: .mic, text: "écho des enceintes"),
            .init(start: 2, end: 3, speakerID: nil, source: .mic, text: "sans voix")]
        var item = Recording(title: "Test", speakers: [me, echo], segments: segments, summary: "old")
        let version = item.transcriptVersion
        try item.setSpeakerIgnored(echo.id, true)
        XCTAssertEqual(item.segments.count, 3, "segments are kept")
        XCTAssertEqual(item.heardSegments.map(\.text), ["bonjour", "sans voix"])
        XCTAssertEqual(item.voiceOverview.map(\.state), [.confirmed, .ignored])
        XCTAssertEqual(item.transcriptVersion, version + 1)
        XCTAssertEqual(item.summary, "old")
        XCTAssertFalse(item.participantNames.contains("à nommer"))
        XCTAssertFalse(SessionExporter.artifact(item, "transcript").contains("écho"))
        XCTAssertFalse(item.searchableText.contains("écho"))
        let document = try SessionExporter.document(item)
        let flags = (document["segments"] as? [[String: Any]])?.compactMap { $0["flags"] as? [String] }
        XCTAssertEqual(flags?[1], ["timing_coarse", "speaker_ignored"])
        XCTAssertEqual(try SummaryPipeline.inputHash(item), try SummaryPipeline.inputHash(item.withoutIgnoredVoices))
        try item.setSpeakerIgnored(echo.id, false)
        XCTAssertEqual(item.heardSegments.count, 3)
        XCTAssertTrue(SessionExporter.artifact(item, "transcript").contains("écho"))
    }

    func testLegacySpeakerPayloadDecodesAsNotIgnored() throws {
        let json = #"{"id":"467F65AC-2420-4C18-9043-CEEA5CE60254","label":"Voix 1","confirmed":false,"source":"mic"}"#
        XCTAssertFalse(try JSONDecoder().decode(Speaker.self, from: Data(json.utf8)).ignored)
    }

    func testMergeCanBeSeparatedLater() throws {
        let brice = Speaker(label: "Brice", confirmed: true), voice3 = Speaker(label: "Voix 3"), voice4 = Speaker(label: "Voix 4")
        var item = Recording(title: "Test", speakers: [brice, voice3, voice4], segments: [
            .init(start: 0, end: 1, speakerID: brice.id, source: .mic, text: "a"),
            .init(start: 1, end: 2, speakerID: voice3.id, source: .mic, text: "b"),
            .init(start: 2, end: 3, speakerID: voice3.id, source: .mic, text: "c"),
            .init(start: 3, end: 4, speakerID: voice4.id, source: .mic, text: "d")], summary: "old")
        try item.mergeSpeaker(voice3.id, into: brice.id)
        try item.mergeSpeaker(voice4.id, into: brice.id)
        XCTAssertEqual(item.speakers.map(\.id), [brice.id])
        XCTAssertEqual(item.separableVoices(of: brice.id).map(\.id), [voice3.id, voice4.id])
        // A passage moved by hand afterwards stays where the user put it.
        try item.assignSpeaker(nil, to: item.segments[2].id)
        let version = item.transcriptVersion
        try item.separateSpeaker(voice3.id, from: brice.id)
        XCTAssertEqual(item.speakers.map(\.id), [brice.id, voice3.id])
        XCTAssertEqual(item.speakers[1].label, "Voix 3")
        XCTAssertFalse(item.speakers[1].confirmed)
        XCTAssertEqual(item.segments.map(\.speakerID), [brice.id, voice3.id, nil, brice.id])
        XCTAssertEqual(item.segments[1].originalSpeakerID, nil)
        XCTAssertEqual(item.separableVoices(of: brice.id).map(\.id), [voice4.id])
        XCTAssertEqual(item.transcriptVersion, version + 1)
        XCTAssertEqual(item.summary, "old")
        XCTAssertThrowsError(try item.separateSpeaker(voice3.id, from: brice.id))
        // The merge history survives a save and is reset by a new transcription.
        let roundtrip = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(roundtrip.absorbedSpeakers?.map(\.id), [voice4.id])
    }

    func testMergingASeparatedVoiceAgainKeepsOneRecord() throws {
        let a = Speaker(label: "A", confirmed: true), b = Speaker(label: "B")
        var item = Recording(title: "Test", speakers: [a, b], segments: [
            .init(start: 0, end: 1, speakerID: a.id, source: .mic, text: "a"),
            .init(start: 1, end: 2, speakerID: b.id, source: .mic, text: "b")])
        try item.mergeSpeaker(b.id, into: a.id)
        try item.separateSpeaker(b.id, from: a.id)
        XCTAssertNil(item.absorbedSpeakers)
        try item.mergeSpeaker(b.id, into: a.id)
        XCTAssertEqual(item.absorbedSpeakers?.map(\.id), [b.id])
    }

    func testSeparatingGivesBackALentIdentity() throws {
        let brice = Speaker(label: "Brice", confirmed: true), voice2 = Speaker(label: "Voix 2")
        var item = Recording(title: "Test", speakers: [brice, voice2], segments: [
            .init(start: 0, end: 1, speakerID: brice.id, source: .mic, text: "a"),
            .init(start: 1, end: 2, speakerID: voice2.id, source: .mic, text: "b")])
        try item.mergeSpeaker(brice.id, into: voice2.id)
        XCTAssertEqual(item.speakers.first?.label, "Brice")
        try item.separateSpeaker(brice.id, from: voice2.id)
        XCTAssertEqual(item.speakers.filter(\.confirmed).map(\.id), [brice.id])
        XCTAssertFalse(item.speakers.first { $0.id == voice2.id }!.confirmed)
    }
}
