import XCTest
@testable import HWYDCore

/// Two channels, deduced from the track, with a stricter cross-channel fallback.
final class VoiceChannelTests: XCTestCase {
    private func unit(_ index: Int, _ tilt: Float = 0) -> [Float] {
        var vector = [Float](repeating: 0, count: 256); vector[index] = 1; vector[index + 1] = tilt
        return try! VoicePrints.normalized(vector)
    }

    func testFormerMicrophoneChannelsReadAsMic() throws {
        let decoded = try JSONDecoder().decode([VoiceChannel].self, from: Data(#"["near","room","remote","mic"]"#.utf8))
        XCTAssertEqual(decoded, [.mic, .mic, .remote, .mic])
        XCTAssertThrowsError(try JSONDecoder().decode(VoiceChannel.self, from: Data(#""elsewhere""#.utf8)))
        var person = VoicePerson(name: "Brice")
        person.enrolledChannels = decoded
        XCTAssertEqual(person.channels, [.mic, .remote])
        XCTAssertEqual(VoiceChannel(source: .mic), .mic)
        XCTAssertEqual(VoiceChannel(source: .system), .remote)
    }

    func testMatchesFromBeforeTheMergeStayReadable() throws {
        let id = UUID()
        let match = try JSONDecoder().decode(VoiceMatch.self, from: Data(#"{"personID":"\#(id.uuidString)","score":0.8,"margin":0.2,"channel":"room"}"#.utf8))
        XCTAssertEqual(match.channel, .mic)
        XCTAssertNil(match.crossChannel)
    }

    func testStoredSamplesKeepTheirOriginAndOldOnesStayReadable() throws {
        let legacy = try VoicePrints.decode(JSONEncoder().encode([unit(0)]))
        XCTAssertEqual(legacy.count, 1)
        XCTAssertNil(legacy[0].recordingID)
        let session = UUID(), speaker = UUID()
        let current = try VoicePrints.decode(JSONEncoder().encode([VoiceExemplar(vector: unit(2), recordingID: session, speakerID: speaker, addedAt: Date())]))
        XCTAssertEqual(current[0].recordingID, session)
        XCTAssertEqual(current[0].speakerID, speaker)
        XCTAssertThrowsError(try VoicePrints.decode(JSONEncoder().encode([[Float](repeating: 0, count: 256)])))
    }

    func testPruningKeepsTheLimitAndOrigins() {
        let session = UUID()
        let values = (0..<25).map { VoiceExemplar(vector: unit($0 * 2, Float($0) / 10), recordingID: $0 < 5 ? session : nil) }
        let kept = VoicePrints.pruned(values)
        XCTAssertEqual(kept.count, VoicePrints.exemplarLimit)
        XCTAssertTrue(kept.allSatisfy { kept in values.contains(kept) })
    }

    func testContributionsGroupSamplesBySessionWithoutVectors() throws {
        let first = UUID(), later = Date()
        let contributions = VoicePrints.contributions(of: [
            VoiceExemplar(vector: unit(0), recordingID: first, addedAt: Date(timeIntervalSince1970: 10)),
            VoiceExemplar(vector: unit(2), recordingID: first, addedAt: later),
            VoiceExemplar(vector: unit(4))], channel: .mic)
        XCTAssertEqual(contributions.count, 2)
        XCTAssertEqual(contributions[0], VoiceContribution(recordingID: first, channel: .mic, count: 2, addedAt: later))
        XCTAssertNil(contributions[1].recordingID)
        let encoded = String(decoding: try JSONEncoder().encode(contributions), as: UTF8.self)
        XCTAssertFalse(encoded.contains("vector"))
    }

    func testSameChannelDecidesAndTheOtherIsALastResort() throws {
        let voice = unit(0)
        // Known on both channels: the voice's own channel decides, even with a worse score.
        let both: [VoiceChannel: [[Float]]] = [.mic: [unit(10)], .remote: [voice]]
        let own = try XCTUnwrap(VoiceResolver.candidate(voice, channel: .mic, exemplars: both))
        XCTAssertEqual(own.channel, .mic)
        XCTAssertFalse(own.crossChannel)
        XCTAssertEqual(own.adjusted, own.score)
        // Known only on the other channel: compared there, held to the stricter threshold.
        let remoteOnly = try XCTUnwrap(VoiceResolver.candidate(voice, channel: .mic, exemplars: [.mic: [], .remote: [voice]]))
        XCTAssertTrue(remoteOnly.crossChannel)
        XCTAssertEqual(remoteOnly.channel, .remote)
        XCTAssertEqual(remoteOnly.adjusted, remoteOnly.score - (VoiceResolver.crossChannelThreshold - VoiceResolver.threshold), accuracy: 1e-9)
        XCTAssertNil(VoiceResolver.candidate(voice, channel: .remote, exemplars: [.mic: [], .remote: []]))
    }

    func testCrossChannelMatchNeedsTheStricterThreshold() {
        // 0.80 passes on the same channel but not across channels.
        let same = VoiceResolver.Candidate(score: 0.80, channel: .mic, crossChannel: false)
        let cross = VoiceResolver.Candidate(score: 0.80, channel: .remote, crossChannel: true)
        let strong = VoiceResolver.Candidate(score: 0.90, channel: .remote, crossChannel: true)
        XCTAssertEqual(VoiceResolver.assign(scores: [[same.adjusted]]), [0])
        XCTAssertEqual(VoiceResolver.assign(scores: [[cross.adjusted]]), [nil])
        XCTAssertEqual(VoiceResolver.assign(scores: [[strong.adjusted]]), [0])
    }

    func testExportReportsTheCrossChannelFallback() throws {
        var speaker = Speaker(label: "Brice", source: .system)
        speaker.proposedIdentity = VoiceMatch(personID: UUID(), score: 0.9, margin: nil, channel: .mic, crossChannel: true)
        let item = Recording(title: "Test", speakers: [speaker], segments: [.init(start: 0, end: 1, speakerID: speaker.id, source: .system, text: "a")])
        let document = try SessionExporter.document(item)
        let identity = try XCTUnwrap(((document["speakers"] as? [[String: Any]])?.first?["identity"]) as? [String: Any])
        let scores = try XCTUnwrap(identity["scores"] as? [String: Any])
        XCTAssertEqual(scores["cross_channel"] as? Bool, true)
        XCTAssertEqual(scores["threshold"] as? Double, VoiceResolver.crossChannelThreshold)
        XCTAssertEqual((document["speakers"] as? [[String: Any]])?.first?["channel"] as? String, "remote")
    }
}
