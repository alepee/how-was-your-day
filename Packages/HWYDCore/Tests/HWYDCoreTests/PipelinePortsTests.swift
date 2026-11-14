import XCTest
@testable import HWYDCore

final class TranscriptionServiceTests: XCTestCase {
    private let locales = SpeechLocales(installed: ["en-US", "fr-FR"], supported: ["de-DE", "en-US", "fr-FR"])

    func testRequestUsesTheOverrideThenTheSessionLanguageThenFrench() {
        var session = Recording(title: "Test")
        session.audioChunks = [.init(source: .mic, relativePath: "a.caf", start: 0, duration: 2)]
        let legacy = TranscriptionRequest(session: session, diarize: true, locales: locales)
        XCTAssertEqual(legacy.locale, "fr-FR")
        XCTAssertEqual(legacy.recordingID, session.id)
        XCTAssertEqual(legacy.chunks, session.audioChunks)
        XCTAssertEqual(legacy.diarize, true)
        XCTAssertNil(legacy.candidateLocales)
        session.speechLanguage = "en-US"
        XCTAssertEqual(TranscriptionRequest(session: session, diarize: false, locales: locales).locale, "en-US")
        XCTAssertEqual(TranscriptionRequest(session: session, language: "de-DE", diarize: false, locales: locales).locale, "de-DE")
    }

    func testAutomaticRequestOffersTheInstalledLanguages() {
        var session = Recording(title: "Test")
        session.speechLanguage = SpeechLanguage.automatic
        let request = TranscriptionRequest(session: session, diarize: false, locales: locales, preferredLanguages: ["en-GB"])
        XCTAssertEqual(request.locale, SpeechLanguage.automatic)
        XCTAssertEqual(request.candidateLocales, ["en-US", "fr-FR"])
        XCTAssertEqual(request.fallbackLocale, "en-US")
        XCTAssertEqual(request.installableLocales, ["de-DE"])
    }

    func testInMemoryServiceRecordsRequestsAndStopsWhenCancelled() async throws {
        let service = InMemoryTranscriptionService { TranscriptionResult(request: $0, segments: []) }
        let request = TranscriptionRequest(recordingID: UUID(), chunks: [])
        let result = try await service.transcribe(request)
        XCTAssertEqual(result.request.recordingID, request.recordingID)
        let task = Task { try await service.transcribe(request) }
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled transcription must not answer") } catch is CancellationError {}
        let count = await service.requests.count
        XCTAssertEqual(count, 2)
    }
}

final class SpeechModelCatalogTests: XCTestCase {
    func testInstallingMarksTheModelReady() async throws {
        let catalog = InMemorySpeechModelCatalog(installed: ["fr-FR"], supported: ["en-US", "fr-FR"])
        try await catalog.install(locale: "en-US")
        let installed = try await catalog.locales().installed
        XCTAssertEqual(installed, ["en-US", "fr-FR"])
        let before = await catalog.diarizerReady()
        XCTAssertFalse(before)
        try await catalog.installDiarizer()
        let after = await catalog.diarizerReady()
        XCTAssertTrue(after)
    }

    func testAFailedInstallLeavesTheModelMissing() async throws {
        let catalog = InMemorySpeechModelCatalog(supported: ["en-US"])
        await catalog.failNextInstall(with: TranscriptionError.unavailable)
        do { try await catalog.installDiarizer(); XCTFail() } catch {}
        let ready = await catalog.diarizerReady()
        XCTAssertFalse(ready)
        do { try await catalog.install(locale: "xx-XX"); XCTFail() } catch {}
        let installed = try await catalog.locales().installed
        XCTAssertEqual(installed, [])
    }
}

final class VoiceMemoryTests: XCTestCase {
    func testSourcesAndForgetPerSession() async throws {
        let memory = InMemoryVoiceMemory()
        let person = UUID(), mic = Speaker(label: "Léa"), remote = Speaker(label: "Léa", source: .system)
        let first = Recording(title: "A", speakers: [mic]), second = Recording(title: "B", speakers: [remote])
        _ = try await memory.enroll(speakerID: mic.id, in: first, as: person)
        _ = try await memory.enroll(speakerID: remote.id, in: second, as: person)
        var sources = try await memory.sources(personID: person)
        XCTAssertEqual(Set(sources.map(\.recordingID)), [first.id, second.id])
        XCTAssertEqual(Set(sources.map(\.channel)), [.mic, .remote])
        try await memory.forget(personID: person, source: first.id)
        sources = try await memory.sources(personID: person)
        XCTAssertEqual(sources.map(\.recordingID), [second.id])
        try await memory.forget(personID: person)
        sources = try await memory.sources(personID: person)
        XCTAssertEqual(sources, [])
    }
}

final class EnrollVoiceTests: XCTestCase {
    func testPersonIsValidatedFoundAndOpposedRefused() throws {
        let lea = VoicePerson(name: "Léa"), excluded = VoicePerson(name: "Hugo", opposed: true)
        let speaker = Speaker(label: "Voix 1")
        XCTAssertThrowsError(try EnrollVoice.person(named: "  ", for: speaker, among: [])) { XCTAssertEqual($0 as? EnrollmentRefusal, .invalidName) }
        XCTAssertThrowsError(try EnrollVoice.person(named: String(repeating: "a", count: 121), for: speaker, among: [])) { XCTAssertEqual($0 as? EnrollmentRefusal, .invalidName) }
        XCTAssertEqual(try EnrollVoice.person(named: " lea ", for: speaker, among: [lea, excluded]).id, lea.id)
        XCTAssertThrowsError(try EnrollVoice.person(named: "hugo", for: speaker, among: [lea, excluded])) { XCTAssertEqual($0 as? EnrollmentRefusal, .opposed(excluded)) }
        let created = try EnrollVoice.person(named: "Camille", for: speaker, among: [lea])
        XCTAssertEqual(created.name, "Camille")
        XCTAssertNotEqual(created.id, lea.id)
        // The voice's own person wins over a namesake.
        let namesake = VoicePerson(name: "Léa")
        var linked = speaker; linked.personID = namesake.id
        XCTAssertEqual(try EnrollVoice.person(named: "Léa", for: linked, among: [lea, namesake]).id, namesake.id)
    }

    func testEnrollmentRecordsTheRequestBeforeTheSample() async throws {
        let people = InMemoryVoicePeople(), memory = InMemoryVoiceMemory()
        let voice = Speaker(label: "Léa", confirmed: true), other = Speaker(label: "Voix 2", source: .system)
        let lea = VoicePerson(name: "Léa")
        await memory.setMatches([other.id: VoiceMatch(personID: lea.id, score: 0.9, margin: 0.2, channel: .remote)])
        var recording = Recording(title: "Test", speakers: [voice, other])
        let date = Date(timeIntervalSince1970: 1000)
        let outcome = try await EnrollVoice(people: people, memory: memory)(lea, speakerID: voice.id, in: recording, at: date)
        XCTAssertEqual(outcome.person.enrollmentRequestedAt, date)
        XCTAssertTrue(outcome.person.recognitionEnabled)
        let samples = await memory.samples
        XCTAssertEqual(samples, [.init(personID: lea.id, recordingID: recording.id, speakerID: voice.id, channel: .mic)])
        let proposed = try recording.applyEnrollment(outcome, speakerID: voice.id)
        XCTAssertEqual(proposed, 1)
        XCTAssertEqual(recording.speakers[0].personID, lea.id)
        XCTAssertTrue(recording.speakers[0].confirmed)
        XCTAssertEqual(recording.speakers[1].proposedIdentity?.personID, lea.id)
        XCTAssertFalse(recording.speakers[1].confirmed)
        XCTAssertEqual(recording.transcriptVersion, 1)
    }

    func testAnOpposedPersonIsNeverEnrolled() async throws {
        let opposed = VoicePerson(name: "Hugo", opposed: true)
        let people = InMemoryVoicePeople([opposed]), memory = InMemoryVoiceMemory()
        let voice = Speaker(label: "Hugo")
        let recording = Recording(title: "Test", speakers: [voice])
        // Under another identity with the same name, the store refuses it.
        do { _ = try await EnrollVoice(people: people, memory: memory)(VoicePerson(name: "hugo"), speakerID: voice.id, in: recording); XCTFail() }
        catch { guard case .consentRequired? = error as? VoiceError else { return XCTFail("\(error)") } }
        do { _ = try await EnrollVoice(people: people, memory: memory)(opposed, speakerID: voice.id, in: recording); XCTFail() }
        catch { XCTAssertEqual(error as? EnrollmentRefusal, .opposed(opposed)) }
        let samples = await memory.samples
        XCTAssertEqual(samples, [])
    }

    func testProposalsSkipConfirmedIgnoredAndUnknownVoices() {
        let known = VoicePerson(name: "Léa")
        let confirmed = Speaker(label: "Moi", confirmed: true)
        var ignored = Speaker(label: "Écho"); ignored.ignored = true
        let open = Speaker(label: "Voix 3"), stranger = Speaker(label: "Voix 4")
        let match = VoiceMatch(personID: known.id, score: 0.8, margin: nil, channel: .mic)
        var recording = Recording(title: "Test", speakers: [confirmed, ignored, open, stranger])
        let count = recording.proposeIdentities([confirmed.id: match, ignored.id: match, open.id: match,
                                                 stranger.id: VoiceMatch(personID: UUID(), score: 0.8, margin: nil, channel: .mic)], people: [known])
        XCTAssertEqual(count, 1)
        XCTAssertEqual(recording.speakers.map(\.label), ["Moi", "Écho", "Léa", "Voix 4"])
        XCTAssertEqual(recording.speakers.map { $0.proposedIdentity != nil }, [false, false, true, false])
        XCTAssertEqual(recording.transcriptVersion, 0)
    }
}

final class SpeakerConfirmationTests: XCTestCase {
    func testMCPRenameConfirmsWithoutEnrolling() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hwyd-confirm-\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try SessionStore(directory: path)
        try await store.setMCPWritesEnabled(true)
        let lea = VoicePerson(name: "Léa"), hugo = VoicePerson(name: "Hugo", opposed: true)
        try await store.savePerson(lea); try await store.savePerson(hugo)
        let voice = Speaker(label: "Voix 1")
        let saved = try await store.save(Recording(title: "Test", speakers: [voice], summary: "old"))
        do { _ = try await store.mutate(id: saved.id, expectedRevision: saved.revision, requestID: UUID(), speaker: voice.id, personID: hugo.id); XCTFail() }
        catch { XCTAssertEqual((error as? IntegrationError)?.code, "PERSON_OPPOSED") }
        do { _ = try await store.mutate(id: saved.id, expectedRevision: saved.revision, requestID: UUID(), speaker: UUID(), personID: lea.id); XCTFail() }
        catch { XCTAssertEqual((error as? IntegrationError)?.code, "NOT_FOUND") }
        _ = try await store.mutate(id: saved.id, expectedRevision: saved.revision, requestID: UUID(), speaker: voice.id, personID: lea.id)
        let renamed = try await store.recording(saved.id)
        XCTAssertEqual(renamed.speakers[0].label, "Léa")
        XCTAssertEqual(renamed.speakers[0].personID, lea.id)
        XCTAssertTrue(renamed.speakers[0].confirmed)
        XCTAssertEqual(renamed.summary, "old")
        // A correction is not consent: the person's enrollment state is untouched.
        let after = try await store.people().first { $0.id == lea.id }
        XCTAssertNil(after?.enrollmentRequestedAt)
        XCTAssertFalse(after?.recognitionEnabled ?? true)
    }
}
