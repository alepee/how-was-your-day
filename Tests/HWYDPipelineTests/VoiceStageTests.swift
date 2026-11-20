import XCTest
import HWYDCore
@testable import HWYDPipeline

/// The voice commands over doubles of their ports: no model, no keychain, no store.
final class VoiceStageTests: XCTestCase {
    private struct Scene {
        let folder: StageFolder
        let vault = InMemorySecretVault()
        var prints: VoicePrints { VoicePrints(vault: vault) }
        let people: InMemoryVoicePeople
        let person: VoicePerson
        var recording: Recording
        /// The voice at level 0.1, and another one at 0.2.
        let voice: Speaker, other: Speaker

        func run(_ command: String, speaker: UUID? = nil, embedder: LevelEmbedder = LevelEmbedder(), source: UUID? = nil) async throws -> Data {
            try await VoiceStage.run(command: command, people: people, audio: folder.audio, prints: prints, embedder: embedder, directory: folder.root,
                                     job: VoiceJob(recording: recording, speakerID: speaker, personID: person.id, sourceRecordingID: source))
        }
        func stored() async throws -> VoicePerson { try await people.people().first { $0.id == person.id }! }
    }

    /// One known person who asked to be memorized, and a call with two voices of 25 s each.
    private func scene() throws -> Scene {
        let folder = try StageFolder()
        var person = VoicePerson(name: "Camille")
        person.enrollmentRequestedAt = Date()
        let voice = Speaker(label: "Voix 1", source: .system), other = Speaker(label: "Voix 2", source: .system)
        var first = try folder.chunk("first.caf", source: .system, seconds: 25, level: 0.1)
        var second = try folder.chunk("second.caf", source: .system, seconds: 25, level: 0.2)
        first.start = 0; second.start = 25
        var recording = Recording(title: "Call", speakers: [voice, other], segments: [
            TranscriptSegment(start: 0, end: 25, speakerID: voice.id, source: .system, text: "…"),
            TranscriptSegment(start: 25, end: 50, speakerID: other.id, source: .system, text: "…")
        ])
        recording.audioChunks = [first, second]
        return Scene(folder: folder, people: InMemoryVoicePeople([person]), person: person, recording: recording, voice: voice, other: other)
    }

    func testEnrollmentStoresThePrintInTheVaultAndNamesOnlyTheMatchingVoice() async throws {
        let scene = try scene()

        let data = try await scene.run("enroll-voice", speaker: scene.voice.id)

        XCTAssertEqual(try scene.prints.vectors(person: scene.person.id, channel: .remote), [LevelEmbedder.vector(level: 0.1)])
        XCTAssertEqual(scene.vault.stored, [VoicePrints.item(scene.person.id, "remote")])
        let stored = try await scene.stored()
        XCTAssertEqual(stored.channels, [.remote])
        XCTAssertNotNil(stored.lastEnrolledAt)
        // The result names the voice and carries no vector.
        let matches = try JSONDecoder().decode([String: VoiceMatch].self, from: data)
        XCTAssertEqual(matches.keys.map { $0 }, [scene.voice.id.uuidString])
        XCTAssertEqual(matches[scene.voice.id.uuidString]?.personID, scene.person.id)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("vector"))
        // The working folder of the job is gone.
        let jobs = try FileManager.default.contentsOfDirectory(atPath: scene.folder.root.appendingPathComponent("jobs").path)
        XCTAssertEqual(jobs, [])
    }

    func testAnOppositionRecordedDuringTheModelRunRefusesTheEnrollment() async throws {
        let scene = try scene()
        var opposed = scene.person
        opposed.opposed = true
        let people = scene.people, refused = opposed
        let embedder = LevelEmbedder(during: { try await people.savePerson(refused) })

        do {
            _ = try await scene.run("enroll-voice", speaker: scene.voice.id, embedder: embedder)
            XCTFail("An opposed person was enrolled.")
        } catch VoiceError.consentRequired {}

        XCTAssertEqual(scene.vault.stored, [])
        let stored = try await scene.stored()
        XCTAssertEqual(stored.channels, [])
    }

    func testEnrollmentNeedsARequestFromThePerson() async throws {
        let scene = try scene()
        var unasked = scene.person
        unasked.enrollmentRequestedAt = nil
        try await scene.people.savePerson(unasked)

        do {
            _ = try await scene.run("enroll-voice", speaker: scene.voice.id)
            XCTFail("A person who asked for nothing was enrolled.")
        } catch VoiceError.consentRequired {}
        XCTAssertEqual(scene.vault.stored, [])
    }

    func testIdentificationDropsAPersonWhoOpposedMeanwhile() async throws {
        let scene = try scene()
        try scene.prints.add(LevelEmbedder.vector(level: 0.2), person: scene.person.id, channel: .remote, recordingID: UUID())
        var enrolled = scene.person
        enrolled.enrolledChannels = [.remote]
        try await scene.people.savePerson(enrolled)

        let found = try JSONDecoder().decode([String: VoiceMatch].self, from: try await scene.run("identify-voices"))
        XCTAssertEqual(found.keys.map { $0 }, [scene.other.id.uuidString])
        XCTAssertEqual(found[scene.other.id.uuidString]?.channel, .remote)

        var opposed = enrolled
        opposed.opposed = true
        let people = scene.people, refused = opposed
        let late = try await scene.run("identify-voices", embedder: LevelEmbedder(during: { try await people.savePerson(refused) }))
        XCTAssertEqual(try JSONDecoder().decode([String: VoiceMatch].self, from: late), [:])
    }

    func testSourcesThenForgettingEmptyTheVault() async throws {
        let scene = try scene()
        _ = try await scene.run("enroll-voice", speaker: scene.voice.id)

        let sources = try JSONDecoder().decode([VoiceContribution].self, from: try await scene.run("voice-sources"))
        XCTAssertEqual(sources.map(\.recordingID), [scene.recording.id])
        XCTAssertEqual(sources.map(\.count), [1])

        _ = try await scene.run("forget-voice-source", source: scene.recording.id)
        XCTAssertEqual(scene.vault.stored, [])
        var stored = try await scene.stored()
        XCTAssertEqual(stored.channels, [])
        XCTAssertNil(stored.lastEnrolledAt)

        _ = try await scene.run("enroll-voice", speaker: scene.voice.id)
        _ = try await scene.run("forget-voice")
        XCTAssertEqual(scene.vault.stored, [])
        stored = try await scene.stored()
        XCTAssertNil(stored.enrolledChannels)
    }

    func testAVoiceWithTooLittleSpeechIsRefusedBeforeTheModel() async throws {
        var scene = try scene()
        scene.recording.segments[0].end = 10
        let embedder = LevelEmbedder(during: { XCTFail("The model ran on 10 s of speech.") })
        do {
            _ = try await scene.run("enroll-voice", speaker: scene.voice.id, embedder: embedder)
            XCTFail("10 s of speech were enough.")
        } catch VoiceError.insufficientSpeech {}
        XCTAssertEqual(scene.vault.stored, [])
    }
}
