import XCTest
@testable import HWYDCore

final class LaunchModeTests: XCTestCase {
    private let app = "/Applications/How Was Your Day.app/Contents/MacOS/HWYD"

    func testTheInstalledAppAndTheExamples() {
        XCTAssertEqual(LaunchMode(arguments: [app]), .app(examples: false))
        XCTAssertEqual(LaunchMode(arguments: [app, "--demo"]), .app(examples: true))
        XCTAssertEqual(LaunchMode(arguments: [app, "-AppleLanguages", "(en)"]), .app(examples: false))
        XCTAssertFalse(LaunchMode.app(examples: true).isSynthetic)
    }

    func testSyntheticModesReadTheirFolder() {
        let folder = URL(fileURLWithPath: "/tmp/checks")
        XCTAssertEqual(LaunchMode(arguments: [app, "--snapshot", "/tmp/checks", "-AppleLanguages", "(en)"]), .snapshot(folder))
        XCTAssertEqual(LaunchMode(arguments: [app, "--ui-test", "/tmp/checks"]), .uiTest(folder))
        XCTAssertEqual(LaunchMode(arguments: [app, "--asr-test", "/tmp/checks"]), .asrTest(folder))
        XCTAssertEqual(LaunchMode(arguments: [app, "--self-test", "/tmp/checks"]), .selfTest(folder, seconds: 2))
        XCTAssertEqual(LaunchMode(arguments: [app, "--self-test", "/tmp/checks", "30"]), .selfTest(folder, seconds: 30))
        // A synthetic flag wins over --demo, and never falls back to the user's data.
        XCTAssertEqual(LaunchMode(arguments: [app, "--demo", "--ui-test", "/tmp/checks"]), .uiTest(folder))
        XCTAssertEqual(LaunchMode(arguments: [app, "--snapshot"]), .preview)
        for mode in [LaunchMode.snapshot(folder), .uiTest(folder), .asrTest(folder), .selfTest(folder, seconds: 2), .preview] {
            XCTAssertTrue(mode.isSynthetic)
        }
    }
}

final class VolatileSettingsTests: XCTestCase {
    func testReadsTheBaseAndNeverWritesIt() {
        let base = InMemorySettings()
        base.set(true, for: .diarizationEnabled)
        base.set("dark", for: .appearance)
        let volatile = VolatileSettings(over: base)
        XCTAssertTrue(volatile.value(.diarizationEnabled))
        volatile.set(false, for: .diarizationEnabled)
        volatile.remove(.appearance)
        XCTAssertFalse(volatile.value(.diarizationEnabled))
        XCTAssertNil(volatile.value(.appearance))
        XCTAssertTrue(base.value(.diarizationEnabled))
        XCTAssertEqual(base.value(.appearance), "dark")
    }
}

final class ExampleServicesTests: XCTestCase {
    func testTheExamplesRefuseEveryJobWithTheirReason() async {
        let pipeline = ExamplePipeline()
        XCTAssertEqual(pipeline.refusal, .examples)
        XCTAssertEqual(WorkRefusal.examples.localizedDescription, "Les exemples ne lancent aucun traitement.")
        let installed = await pipeline.diarizerReady()
        XCTAssertFalse(installed)
        do { _ = try await pipeline.locales(); XCTFail("The examples read no language") } catch { XCTAssertEqual(error as? WorkRefusal, .examples) }
        do { try await pipeline.forget(personID: UUID()); XCTFail("The examples erase no print") } catch { XCTAssertEqual(error as? WorkRefusal, .examples) }
        XCTAssertNil(InMemoryVoiceMemory().refusal)
        XCTAssertNil(InMemorySpeechModelCatalog().refusal)
    }

    func testARefusingSummarizerShowsTheConfiguredOne() async {
        let shown = UnavailableSummarizer(reason: .disabled)
        let summarizer = RefusingSummarizer(showing: shown)
        XCTAssertEqual(summarizer.availability, shown.availability)
        XCTAssertEqual(summarizer.disclosure, shown.disclosure)
        XCTAssertEqual(summarizer.refusal, .examples)
        XCTAssertNil(shown.refusal)
        do { _ = try await summarizer.summarize(Recording(title: "Test")) { _ in }; XCTFail("Must refuse") }
        catch { XCTAssertEqual(error as? WorkRefusal, .examples) }
    }

    func testRefusalsSayWhy() {
        XCTAssertEqual(WorkRefusal.noAudio.localizedDescription, "Aucun fichier audio disponible pour cette session.")
        XCTAssertEqual(WorkRefusal.sessionNotFound.localizedDescription, "Session introuvable sur ce Mac.")
        XCTAssertEqual(WorkRefusal.storeUnavailable.localizedDescription, "Le store local n’est pas disponible.")
    }
}

@MainActor
final class VoiceRequestsTests: XCTestCase {
    private func fixture() -> (Recording, Speaker, Speaker) {
        let first = Speaker(label: "Voix 1", source: .mic), second = Speaker(label: "Voix 2", source: .mic)
        var item = Recording(title: "Voix", speakers: [first, second], segments: [
            .init(start: 0, end: 30, speakerID: first.id, source: .mic, text: "a"),
            .init(start: 30, end: 60, speakerID: second.id, source: .mic, text: "b")])
        item.audioChunks = [.init(source: .mic, relativePath: "a.caf", start: 0, duration: 60)]
        return (item, first, second)
    }

    func testEnrollmentConfirmsTheVoiceAndReportsProposals() async throws {
        let (item, first, _) = fixture()
        let library = SessionLibrary(volatile: [item])
        let memory = InMemoryVoiceMemory(), people = InMemoryVoicePeople()
        let requests = VoiceRequests(people: people, memory: memory)
        let lea = VoicePerson(name: "Léa")
        let result = try await requests.enroll(lea, speakerID: first.id, in: item, library: library)
        XCTAssertEqual(result.outcome, .enrolled(name: "Léa", proposals: 0))
        XCTAssertEqual(result.people.map(\.name), ["Léa"])
        XCTAssertEqual(library.recording(item.id)?.speakers.first?.personID, lea.id)
        let samples = await memory.samples
        XCTAssertEqual(samples.count, 1)
    }

    func testAnOutdatedResultLeavesTheSessionAlone() async throws {
        let (item, first, _) = fixture()
        let library = SessionLibrary(volatile: [item])
        library.edit(item.id) { $0.transcriptVersion += 1 }
        let requests = VoiceRequests(people: InMemoryVoicePeople(), memory: InMemoryVoiceMemory())
        let enrolled = try await requests.enroll(VoicePerson(name: "Léa"), speakerID: first.id, in: item, library: library)
        XCTAssertEqual(enrolled.outcome, .enrolledSessionChanged(name: "Léa"))
        XCTAssertNil(library.recording(item.id)?.speakers.first?.personID)
        let identified = try await requests.identify(in: item, library: library)
        XCTAssertEqual(identified.outcome, .identificationSessionChanged)
    }

    func testOppositionErasesThenCanBeLifted() async throws {
        let (item, first, _) = fixture()
        let library = SessionLibrary(volatile: [item])
        let memory = InMemoryVoiceMemory(), people = InMemoryVoicePeople()
        let requests = VoiceRequests(people: people, memory: memory)
        let enrolled = try await requests.enroll(VoicePerson(name: "Camille"), speakerID: first.id, in: item, library: library)
        let camille = try XCTUnwrap(enrolled.people.first)
        let sources = try await requests.sources(of: camille.id)
        guard case .read(camille.id, let read)? = sources.contributions else { return XCTFail("Contributions not read") }
        XCTAssertFalse(read.isEmpty)
        let opposed = try await requests.oppose(camille)
        XCTAssertEqual(opposed.outcome, .opposed(name: "Camille"))
        XCTAssertEqual(opposed.contributions, .cleared(personID: camille.id))
        XCTAssertEqual(opposed.people.first?.opposed, true)
        let remaining = await memory.samples
        XCTAssertTrue(remaining.isEmpty)
        let lifted = try await requests.liftOpposition(camille)
        XCTAssertEqual(lifted.outcome, .oppositionLifted(name: "Camille"))
        XCTAssertEqual(lifted.people.first?.opposed, false)
        XCTAssertNil(lifted.people.first?.enrollmentRequestedAt)
    }
}
