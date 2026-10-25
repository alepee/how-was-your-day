import XCTest
@testable import HWYDCore

final class IntegrationTests: XCTestCase, @unchecked Sendable {
    func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hwyd-integration-\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    func testMutationGateCASIdempotencyAndSearch() async throws {
        let path = try directory(), store = try SessionStore(directory: path)
        let r = try await store.save(Recording(title: "Une réunion", notes: "ancien"))
        let request = UUID()
        do { _ = try await store.mutate(id: r.id, expectedRevision: r.revision, requestID: request, notes: "nouveau"); XCTFail() }
        catch { XCTAssertEqual((error as? IntegrationError)?.code, "WRITE_DISABLED") }
        try await store.setSetting("mcp_writes_enabled", value: "true")
        let first = try await store.mutate(id: r.id, expectedRevision: r.revision, requestID: request, notes: "Décision nouvelle")
        let retry = try await store.mutate(id: r.id, expectedRevision: r.revision, requestID: request, notes: "Décision nouvelle")
        XCTAssertEqual(first.revision, retry.revision)
        do { _ = try await store.mutate(id: r.id, expectedRevision: r.revision, requestID: UUID(), notes: "perdu"); XCTFail() }
        catch { XCTAssertEqual((error as? IntegrationError)?.code, "VERSION_CONFLICT") }
        do { _ = try await store.mutate(id: r.id, expectedRevision: r.revision, requestID: request, notes: "différent"); XCTFail() }
        catch { XCTAssertEqual((error as? IntegrationError)?.code, "IDEMPOTENCY_CONFLICT") }
        let hits = try await store.search("decision")
        XCTAssertEqual(hits.first?.recordingID, r.id)
        let readonly = try SessionStore(directory: path, readOnly: true, migrate: false)
        let loaded = try await readonly.recording(r.id)
        XCTAssertEqual(loaded.notes, "Décision nouvelle")
        XCTAssertEqual(loaded.notesVersion, 2)
        try await store.setSetting("mcp_writes_enabled", value: "false")
        do { _ = try await store.mutate(id: r.id, expectedRevision: first.revision, requestID: UUID(), notes: "perdu"); XCTFail() }
        catch { XCTAssertEqual((error as? IntegrationError)?.code, "WRITE_DISABLED") }
    }
    func testReadOnlyCannotInitializeStore() throws {
        XCTAssertThrowsError(try SessionStore(directory: directory(), readOnly: true, migrate: false))
    }
    func testExportRecoveryAndExternalEditPreserved() throws {
        let path = try directory()
        var r = Recording(title: "Titre\n---\ninjection: true")
        r.revision = 1; r.notes = "Note"
        r.audioChunks = [.init(source: .mic, relativePath: "secret-location/audio.caf", start: 0, duration: 1)]
        try SessionExporter.export(r, to: path)
        let index = path.appendingPathComponent("index.jsonl")
        var data = try Data(contentsOf: index); data.append(Data("{incomplete".utf8)); try data.write(to: index)
        let flat = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil).first { $0.pathExtension == "md" }!
        try Data("Édition externe".utf8).write(to: flat)
        r.revision = 2; r.notes = "Nouvelle note"
        try SessionExporter.export(r, to: path)
        let events = try String(contentsOf: index, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(events.count, 2)
        let conflicts = try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".conflict-") }
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(try String(contentsOf: conflicts[0], encoding: .utf8), "Édition externe")
        let document = String(decoding: try JSONSerialization.data(withJSONObject: SessionExporter.document(r)), as: UTF8.self)
        XCTAssertFalse(document.contains("secret-location")); XCTAssertFalse(document.contains("consentedAt"))
        r.notes = "Different same revision"
        XCTAssertThrowsError(try SessionExporter.export(r, to: path))
    }
    func testVoiceAssignmentRejectsAmbiguityAndResolvesCollisions() throws {
        XCTAssertEqual(VoiceResolver.assign(scores: [[0.9, 0.85], [0.5, 0.4]]), [nil, nil])
        XCTAssertEqual(VoiceResolver.assign(scores: [[0.9, 0.2], [0.95, 0.1], [0.1, 0.88]]), [nil, 0, 1])
        XCTAssertEqual(VoiceResolver.assign(scores: [[0.8], [0.9]]), [nil, 0])
        XCTAssertThrowsError(try VoiceKeychain.normalized([Float](repeating: 0, count: 256)))
        XCTAssertThrowsError(try VoiceKeychain.normalized([1, 2]))
        var vector = [Float](repeating: 0, count: 256); vector[0] = 2
        XCTAssertEqual(try VoiceKeychain.normalized(vector)[0], 1)
    }
    func testOppositionCannotBeOverwrittenOrDuplicated() async throws {
        let store = try SessionStore(directory: directory())
        let p = VoicePerson(name: "Voix synthétique", opposed: true)
        try await store.savePerson(p)
        do { try await store.savePerson(.init(id: p.id, name: p.name, consentedAt: Date())); XCTFail() } catch {}
        do { try await store.savePerson(.init(name: "voix synthetique", consentedAt: Date())); XCTFail() } catch {}
        let people = try await store.people(); XCTAssertEqual(people.count, 1)
    }
    func testSummaryGroundingAndLocalEndpoint() async throws {
        let r = DemoContent.recordings()[0]
        let hash = try SummaryPipeline.inputHash(r)
        for _ in 0..<10 { XCTAssertEqual(try SummaryPipeline.inputHash(r), hash) }
        XCTAssertThrowsError(try LocalLLMProvider(endpoint: URL(string: "https://example.com/v1")!, model: "test"))
        XCTAssertThrowsError(try LocalLLMProvider(endpoint: URL(string: "http://user@localhost/v1")!, model: "test"))
        _ = try LocalLLMProvider(endpoint: URL(string: "http://127.0.0.1:1234/v1")!, model: "test")
        let good = SummaryContent(overview: "Synthèse de test", decisions: [.init(text: "Décision", evidence_segment_ids: [r.segments[0].id])], action_items: [])
        let result = try await SummaryPipeline.run(r, provider: FixtureLLM(content: good), model: "fixture")
        XCTAssertEqual(result.inputHash, hash)
        var bad = good; bad.decisions[0].evidence_segment_ids = [UUID()]
        XCTAssertThrowsError(try SummaryPipeline.validate(bad, segments: r.segments))
        bad = good; bad.action_items = [.init(text: "Action", assignee_person_id: UUID(), due_date: nil, evidence_segment_ids: [r.segments[0].id])]
        XCTAssertThrowsError(try SummaryPipeline.validate(bad, segments: r.segments))
    }
}
private struct FixtureLLM: LLMProvider {
    var content: SummaryContent
    func generate(prompt: String) async throws -> SummaryContent { content }
}

extension IntegrationTests {
    func testLocalHTTPProviderWhenFixtureIsRunning() async throws {
        guard let raw = ProcessInfo.processInfo.environment["HWYD_TEST_LLM_URL"], let url = URL(string: raw) else { throw XCTSkip("Fixture HTTP non lancée") }
        let r = DemoContent.recordings()[0]
        let result = try await SummaryPipeline.run(r, provider: LocalLLMProvider(endpoint: url, model: "synthetic-fixture"), model: "synthetic-fixture")
        XCTAssertEqual(result.structured.overview, "Synthèse HTTP synthétique")
        XCTAssertEqual(result.structured.decisions.first?.evidence_segment_ids, [r.segments[0].id])
    }
    func testDeletionPublishesTombstoneAndPreventsResurrection() async throws {
        let store = try SessionStore(directory: directory()), output = try directory()
        try await store.setSetting("export_directory", value: output.path)
        let r = try await store.save(Recording(title: "Test de suppression"))
        try await store.publishPending()
        try await store.remove(r.id)
        try await store.publishPending()
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent(".hwyd/generations/" + r.id.uuidString.lowercased()).path))
        let lines = try String(contentsOf: output.appendingPathComponent("index.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.last!.contains("delete"))
        XCTAssertThrowsError(try SessionExporter.export(r, to: output))
    }
}


extension IntegrationTests {
    func testLiveLocalSummaryWhenRequested() async throws {
        guard let raw = ProcessInfo.processInfo.environment["HWYD_LIVE_LLM_URL"], let url = URL(string: raw) else { throw XCTSkip("Modèle local réel non demandé") }
        var recording = Recording(title: "Test synthétique de synthèse", isDemo: true)
        recording.segments = [.init(start: 0, end: 8, speakerID: nil, source: .mic, text: "On valide la migration du service. Je préparerai le document demain.")]
        let model = ProcessInfo.processInfo.environment["HWYD_LIVE_LLM_MODEL"] ?? "google/gemma-4-e4b"
        let result = try await SummaryPipeline.run(recording, provider: LocalLLMProvider(endpoint: url, model: model), model: model)
        XCTAssertFalse(result.structured.overview.isEmpty)
        XCTAssertFalse(result.structured.decisions.isEmpty, "La décision explicite doit être extraite")
        XCTAssertFalse(result.structured.action_items.isEmpty, "La tâche promise doit être extraite")
        XCTAssertEqual(result.model, model)
        XCTAssertEqual(result.inputHash, try SummaryPipeline.inputHash(recording))
    }
}

extension IntegrationTests {
    func testSummaryRejectsTranscriptDumpAndInternalReferences() throws {
        let segment = TranscriptSegment(start: 0, end: 20, speakerID: nil, source: .mic, text: "Donc je suis dans mes outils, je ne les ai pas encore tous partagés parce que ce sont plutôt des outils métiers.")
        let dumped = SummaryContent(overview: "Discussion sur le partage d’outils.", decisions: [], action_items: [.init(text: segment.text, assignee_person_id: nil, due_date: nil, evidence_segment_ids: [segment.id])])
        XCTAssertThrowsError(try SummaryPipeline.validate(dumped, segments: [segment]))
        let leaked = SummaryContent(overview: "Les segments S1 à S12 parlent des outils.", decisions: [], action_items: [])
        XCTAssertThrowsError(try SummaryPipeline.validate(leaked, segments: [segment]))
        let noCommitment = SummaryContent(overview: "Les participants envisagent de partager leurs outils métiers.", decisions: [], action_items: [])
        XCTAssertNoThrow(try SummaryPipeline.validate(noCommitment, segments: [segment]))
        let fakeEmpty = SummaryContent(overview: noCommitment.overview, decisions: [], action_items: [.init(text: "Aucune action explicite", assignee_person_id: nil, due_date: nil, evidence_segment_ids: [segment.id])])
        XCTAssertThrowsError(try SummaryPipeline.validate(fakeEmpty, segments: [segment]))
    }
}

extension IntegrationTests {
    func testDetailedSummaryCompatibilityAndGrounding() throws {
        let legacy = Data(#"{"overview":"Ancien résumé","decisions":[],"action_items":[]}"#.utf8)
        let old = try JSONDecoder().decode(SummaryContent.self, from: legacy)
        XCTAssertNil(old.details)
        let segment = TranscriptSegment(start: 42, end: 60, speakerID: nil, source: .mic, text: "Le plugin distribue plusieurs skills ensemble.")
        var summary = SummaryContent(overview: "Discussion sur les plugins.", decisions: [], action_items: [])
        summary.key_points = [.init(title: "Distribution", text: "Les skills sont regroupés.", evidence_segment_ids: [segment.id])]
        summary.details = [.init(title: "Rôle du plugin", text: "Un plugin permet de distribuer plusieurs skills ensemble.", evidence_segment_ids: [segment.id])]
        try SummaryPipeline.validate(summary, segments: [segment])
        XCTAssertTrue(summary.markdown.contains("## Résumé"))
        XCTAssertTrue(summary.markdown.contains("## Détails"))
        XCTAssertFalse(summary.markdown.contains("## Étapes suivantes"))
        XCTAssertEqual(try JSONDecoder().decode(SummaryContent.self, from: JSONEncoder().encode(summary)), summary)
        var attributed = summary
        let speaker = Speaker(label: "Camille", confirmed: true)
        var spoken = segment; spoken.speakerID = speaker.id
        attributed.action_items = [.init(text: "Préparer les maquettes.", assignee_name: "Camille", assignee_person_id: nil, due_date: nil, evidence_segment_ids: [spoken.id])]
        XCTAssertNoThrow(try SummaryPipeline.validate(attributed, segments: [spoken], speakers: [speaker]))
        attributed.action_items[0].assignee_name = "Nom inventé"
        XCTAssertThrowsError(try SummaryPipeline.validate(attributed, segments: [spoken], speakers: [speaker]))
        summary.details?[0].evidence_segment_ids = [UUID()]
        XCTAssertThrowsError(try SummaryPipeline.validate(summary, segments: [segment]))
    }
}

private actor DetailedFixtureLLM: LLMProvider {
    var calls = 0
    func generate(prompt: String) async throws -> SummaryContent { throw SummaryFailure.invalidResponse }
    func generate(prompt: String, evidenceIDs: [UUID]) async throws -> SummaryContent {
        calls += 1
        var result = SummaryContent(overview: "Compte rendu global.", decisions: [], action_items: [])
        if prompt.hasPrefix("Passe spécialisée") { result.overview = "" }
        result.key_points = []
        result.details = [.init(title: "Sujet", text: "Explication du sujet.", evidence_segment_ids: Array(evidenceIDs.prefix(3)))]
        return result
    }
}
extension IntegrationTests {
    func testLongSummaryReducesWindowsToOneReport() async throws {
        var recording = Recording(title: "Longue session synthétique", isDemo: true)
        recording.segments = (0..<3).map { index in
            .init(start: Double(index * 60), end: Double(index * 60 + 50), speakerID: nil, source: .mic, text: String(repeating: "Sujet discuté. ", count: 500))
        }
        let provider = DetailedFixtureLLM()
        let result = try await SummaryPipeline.run(recording, provider: provider, model: "fixture")
        let calls = await provider.calls
        XCTAssertEqual(calls, 8)
        XCTAssertEqual(result.structured.overview, "Compte rendu global.")
        XCTAssertEqual(result.structured.details?.count, 1)
        XCTAssertEqual(result.promptVersion, "summary-v4")
    }
}

extension IntegrationTests {
    func testLiveDetailedSummaryWhenRequested() async throws {
        guard let raw = ProcessInfo.processInfo.environment["HWYD_LIVE_LLM_URL"], let url = URL(string: raw) else { throw XCTSkip("Modèle local réel non demandé") }
        let speaker = Speaker(label: "Camille", confirmed: true)
        var recording = Recording(title: "Atelier synthétique", kind: .voiceMemo, speakers: [speaker], isDemo: true)
        recording.segments = [
            .init(start: 0, end: 30, speakerID: speaker.id, source: .mic, text: "Un plugin regroupe plusieurs skills que l'on distribue ensemble. Les skills restent des composants distincts. Quand on corrige le composant partagé, les plugins qui le référencent profitent de la correction. C'est comme un classeur de recettes. Nous validons ce regroupement par tâche plutôt que par équipe."),
            .init(start: 40, end: 60, speakerID: speaker.id, source: .mic, text: "Autre sujet : le calendrier doit rester facultatif. Une idée peut arriver sans réunion prévue. On décide de garder un bouton d'enregistrement immédiat. Je préparerai deux maquettes pour comparer les parcours."),
            .init(start: 70, end: 90, speakerID: speaker.id, source: .mic, text: "Pour l'audio en salle, les personnes éloignées sont difficiles à entendre. Un micro au centre pourrait aider mais personne n'a testé cette solution. Le choix du micro reste ouvert. Nous n'avons pas encore de budget.")
        ]
        let model = ProcessInfo.processInfo.environment["HWYD_LIVE_LLM_MODEL"] ?? "google/gemma-4-e4b"
        let result = try await SummaryPipeline.run(recording, provider: LocalLLMProvider(endpoint: url, model: model), model: model)
        XCTAssertGreaterThanOrEqual(result.structured.details?.count ?? 0, 3)
        XCTAssertFalse(result.structured.action_items.isEmpty)
        XCTAssertFalse(result.structured.decisions.isEmpty)
        XCTAssertTrue(result.structured.action_items.allSatisfy { $0.due_date == nil })
        print("DETAILED_SUMMARY_REVIEW\n" + result.structured.markdown)
    }
}
