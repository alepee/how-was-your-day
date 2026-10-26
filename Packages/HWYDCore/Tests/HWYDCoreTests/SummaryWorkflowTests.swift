import XCTest
@testable import HWYDCore

private actor WorkflowProvider: LLMProvider {
    var prompts: [String] = []
    var failWriting = false
    func failNextWriting() { failWriting = true }
    func generate(prompt: String) async throws -> SummaryContent { throw SummaryFailure.invalidResponse }
    func plan(prompt: String, evidenceIDs: [UUID]) async throws -> SummaryContent {
        prompts.append("plan:" + prompt)
        return content(evidenceIDs)
    }
    func generate(prompt: String, evidenceIDs: [UUID]) async throws -> SummaryContent {
        prompts.append("write:" + prompt)
        if failWriting { failWriting = false; throw SummaryFailure.invalidResponse }
        return content(evidenceIDs)
    }
    func content(_ ids: [UUID]) -> SummaryContent {
        var result = SummaryContent(overview: "Un atelier sur les accès.", decisions: [], action_items: [])
        result.details = [.init(title: "Accès", text: "Le groupe étudie les accès temporaires.", evidence_segment_ids: Array(ids.prefix(1)))]
        return result
    }
}

final class SummaryWorkflowTests: XCTestCase, @unchecked Sendable {
    func fixture() -> Recording {
        Recording(title: "Atelier", segments: [.init(start: 0, end: 10, speakerID: nil, source: .mic, text: "Nous discutons des accès temporaires et de leur révocation.")])
    }
    func testSecondPassReadsOriginalAndResumesValidatedPlan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = WorkflowProvider(), recording = fixture()
        await provider.failNextWriting()
        do { _ = try await SummaryPipeline.run(recording, provider: provider, model: "fixture", cacheDirectory: directory); XCTFail() }
        catch SummaryFailure.invalidResponse {}
        _ = try await SummaryPipeline.run(recording, provider: provider, model: "fixture", cacheDirectory: directory)
        let prompts = await provider.prompts
        XCTAssertEqual(prompts.filter { $0.hasPrefix("plan:") }.count, 1)
        XCTAssertEqual(prompts.filter { $0.hasPrefix("write:") }.count, 2)
        XCTAssertTrue(prompts.contains { $0.hasPrefix("write:WRITE_TOPIC") && $0.contains(recording.segments[0].text) })
        XCTAssertTrue(prompts.contains { $0.contains("topic_map") })
        _ = try await SummaryPipeline.run(recording, provider: provider, model: "fixture", cacheDirectory: directory)
        let afterCache = await provider.prompts.count
        XCTAssertEqual(afterCache, 3)
        _ = try await SummaryPipeline.run(recording, provider: provider, model: "different", cacheDirectory: directory)
        let afterModel = await provider.prompts.count
        XCTAssertEqual(afterModel, 5)
    }
    func testSpeakerCorrectionsInvalidateFingerprint() throws {
        var recording = fixture()
        let before = try SummaryPipeline.inputHash(recording)
        recording.speakers = [.init(label: "Camille", confirmed: true)]
        XCTAssertNotEqual(try SummaryPipeline.inputHash(recording), before)
    }
    func testUnavailableCacheDoesNotDiscardResult() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let provider = WorkflowProvider()
        let result = try await SummaryPipeline.run(fixture(), provider: provider, model: "fixture", cacheDirectory: path)
        XCTAssertFalse(result.structured.overview.isEmpty)
    }
    func testMoreThanEightLegitimateActionsAreAccepted() throws {
        let recording = fixture()
        let result = SummaryContent(overview: "Atelier.", decisions: [], action_items: (1...9).map {
            SummaryAction(text: "Préparer le document \($0).", assignee_person_id: nil, due_date: nil, evidence_segment_ids: [recording.segments[0].id])
        })
        XCTAssertNoThrow(try SummaryPipeline.validate(result, segments: recording.segments))
    }
    func testRealRecordingWhenExplicitlyRequested() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["HWYD_SUMMARY_RECORDING"], let output = env["HWYD_SUMMARY_OUTPUT"] else { throw XCTSkip("Private benchmark not requested") }
        let recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = env["HWYD_LIVE_LLM_MODEL"] ?? "google/gemma-4-e4b"
        let endpoint = URL(string: env["HWYD_LIVE_LLM_URL"] ?? "http://127.0.0.1:1234/v1")!
        let provider = BenchmarkProvider(base: try LocalLLMProvider(endpoint: endpoint, model: model, reasoningEffort: env["HWYD_LIVE_LLM_REASONING_EFFORT"]))
        let started = Date()
        let result = try await SummaryPipeline.run(recording, provider: provider, model: model, inputCharacterLimit: Int(env["HWYD_SUMMARY_INPUT_CHARACTER_LIMIT"] ?? "24000") ?? 24000,
            cacheDirectory: directory.appendingPathComponent("cache"), providerIdentity: endpoint.absoluteString + "|reasoning=" + (env["HWYD_LIVE_LLM_REASONING_EFFORT"] ?? "default")) { progress in
                print("BENCHMARK \(progress.stage) \(progress.completed)/\(progress.total) cached=\(progress.cached)")
            }
        try await provider.writeMetrics(to: directory.appendingPathComponent("metrics.json"))
        try JSONEncoder().encode(result).write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        try result.structured.markdown.write(to: directory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        try "Elapsed seconds: \(Date().timeIntervalSince(started))\nModel: \(model)\n".write(to: directory.appendingPathComponent("timing.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(result.structured.details?.isEmpty ?? true)
    }
}

private actor BenchmarkProvider: LLMProvider {
    let base: LocalLLMProvider
    var calls = 0, maxCharacters = 0
    var inferenceSeconds = 0.0
    init(base: LocalLLMProvider) { self.base = base }
    func generate(prompt: String) async throws -> SummaryContent { try await generate(prompt: prompt, evidenceIDs: []) }
    func generate(prompt: String, evidenceIDs: [UUID]) async throws -> SummaryContent { try await invoke(prompt, evidenceIDs, planning: false) }
    func plan(prompt: String, evidenceIDs: [UUID]) async throws -> SummaryContent { try await invoke(prompt, evidenceIDs, planning: true) }
    func invoke(_ prompt: String, _ ids: [UUID], planning: Bool) async throws -> SummaryContent {
        calls += 1; maxCharacters = max(maxCharacters, prompt.count)
        let start = Date()
        defer { inferenceSeconds += Date().timeIntervalSince(start) }
        return try await planning ? base.plan(prompt: prompt, evidenceIDs: ids) : base.generate(prompt: prompt, evidenceIDs: ids)
    }
    func writeMetrics(to url: URL) throws {
        let value: [String: Any] = ["model_calls": calls, "max_input_characters": maxCharacters, "inference_seconds": inferenceSeconds]
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
    }
}

extension SummaryWorkflowTests {
    func testLargeConfiguredContextStillBoundsRequestsAndWritesEveryBilingualTurn() async throws {
        let provider = WorkflowProvider()
        var recording = fixture()
        recording.segments = (0..<40).map { index in
            .init(start: Double(index * 60), end: Double(index * 60 + 50), speakerID: nil, source: .mic,
                  text: "TURN_\(index) " + String(repeating: index.isMultiple(of: 2) ? "Discussion des accès et de la révocation. " : "We discuss access and the revocation process. ", count: 50))
        }
        _ = try await SummaryPipeline.run(recording, provider: provider, model: "fixture", inputCharacterLimit: 500_000)
        let prompts = await provider.prompts
        XCTAssertLessThanOrEqual(prompts.map(\.count).max()!, SummaryPipeline.maximumInputCharacters + 6)
        let writings = prompts.filter { $0.hasPrefix("write:WRITE_TOPIC:") }
        for index in 0..<40 { XCTAssertTrue(writings.contains { $0.contains("TURN_\(index) ") }, "Missing turn \(index)") }
        XCTAssertGreaterThan(writings.count, 1)
        XCTAssertFalse(writings.contains { $0.contains("TURN_0 ") && $0.contains("TURN_39 ") })
    }
    func testOversizedTurnFailsBeforeInferenceInsteadOfTruncating() async throws {
        let provider = WorkflowProvider()
        var recording = fixture()
        recording.segments[0].text = String(repeating: "Un très long tour. ", count: 2000)
        do { _ = try await SummaryPipeline.run(recording, provider: provider, model: "fixture"); XCTFail("Expected explicit context failure") }
        catch SummaryFailure.contextTooSmall {}
        let calls = await provider.prompts.count
        XCTAssertEqual(calls, 0)
    }
    func testCancellationUnderAnotherTopicRepairsDetailsAsWellAsActions() async throws {
        let speaker = Speaker(label: "Camille", confirmed: true)
        let texts = ["Je promets de publier le lancement vendredi. INITIAL_COMMITMENT. ", "Nous abordons les accès techniques. ", "We discuss the finance budget. ", "ANNULÉ : le lancement est annulé. Do not publish on Friday. "]
        let recording = Recording(title: "Mixed discussion", speakers: [speaker], segments: texts.enumerated().map { index, text in
            .init(start: Double(index * 100), end: Double(index * 100 + 90), speakerID: speaker.id, source: .mic, text: text + String(repeating: "Contexte explicatif sans engagement supplémentaire. ", count: 75))
        })
        let provider = CancellationProvider()
        let result = try await SummaryPipeline.run(recording, provider: provider, model: "fixture", inputCharacterLimit: 12_000)
        XCTAssertTrue(result.structured.action_items.isEmpty)
        XCTAssertFalse(result.structured.markdown.contains("ENGAGEMENT_ACTIF"))
        XCTAssertTrue(result.structured.markdown.contains("annulé"))
        let prompts = await provider.prompts
        XCTAssertTrue(prompts.contains { $0.hasPrefix("REPAIR:") })
        XCTAssertLessThanOrEqual(prompts.map(\.count).max()!, 12_000)
    }
}

private actor CancellationProvider: LLMProvider {
    var prompts: [String] = []
    func generate(prompt: String) async throws -> SummaryContent { throw SummaryFailure.invalidResponse }
    func plan(prompt: String, evidenceIDs: [UUID]) async throws -> SummaryContent { try await generate(prompt: prompt, evidenceIDs: evidenceIDs) }
    func generate(prompt: String, evidenceIDs: [UUID]) async throws -> SummaryContent {
        prompts.append(prompt)
        var result = SummaryContent(overview: "Le lancement est discuté.", decisions: [], action_items: [], key_points: [], details: [])
        func sourceID(containing marker: String) -> UUID? {
            guard let newline = prompt.firstIndex(of: "\n"), let data = String(prompt[prompt.index(after: newline)...]).data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
            let rows = (object as? [[String: Any]]) ?? ((object as? [String: Any])?["original_transcript"] as? [[String: Any]]) ?? []
            guard let row = rows.first(where: { ($0["text"] as? String)?.contains(marker) == true }), let id = row["id"] as? String, let number = Int(id.dropFirst()), evidenceIDs.indices.contains(number - 1) else { return nil }
            return evidenceIDs[number - 1]
        }
        if prompt.hasPrefix("ROUTE:") {
            result.details = evidenceIDs.enumerated().map { .init(title: "Topic \($0.offset)", text: "Périmètre distinct.", evidence_segment_ids: [$0.element]) }
        } else if prompt.hasPrefix("VERIFY_") {
            if let cancellation = sourceID(containing: "ANNULÉ") {
                result.details = [.init(title: "Annulation du lancement", text: "Le lancement a été annulé après la promesse initiale.", evidence_segment_ids: [cancellation])]
            } else if let initial = sourceID(containing: "INITIAL_COMMITMENT") {
                result.action_items = [.init(text: "Publier le lancement vendredi.", assignee_name: "Camille", assignee_person_id: nil, due_date: nil, evidence_segment_ids: [initial])]
            }
        } else if prompt.hasPrefix("REPAIR:") {
            let id = sourceID(containing: "ANNULÉ") ?? evidenceIDs[0]
            result.details = [.init(title: "Lancement annulé", text: "La promesse initiale de lancement a ensuite été annulée.", evidence_segment_ids: [id])]
        } else if prompt.hasPrefix("EXECUTIVE:") {
            result.overview = "Le lancement a finalement été annulé."
        } else {
            let initial = sourceID(containing: "INITIAL_COMMITMENT")
            result.details = [.init(title: initial == nil ? "Budget et suites" : "Lancement", text: initial == nil ? "La discussion porte sur les suites du projet." : "ENGAGEMENT_ACTIF : le lancement sera publié vendredi.", evidence_segment_ids: [initial ?? evidenceIDs[0]])]
            if prompt.hasPrefix("EXTRACT:"), let initial {
                result.action_items = [.init(text: "Publier le lancement vendredi.", assignee_name: "Camille", assignee_person_id: nil, due_date: nil, evidence_segment_ids: [initial])]
            }
        }
        return result
    }
}

extension SummaryWorkflowTests {
    func testStageSystemsDoNotInheritReportWritingInstructions() {
        for prefix in ["ROUTE:", "VERIFY_ACTIONS:", "VERIFY_DECISIONS:", "REPAIR:", "EXECUTIVE:"] {
            let system = LocalLLMProvider.systemInstructions(for: prefix + "\n{}", planning: prefix == "ROUTE:")
            XCTAssertNotEqual(system, SummaryPipeline.instructions)
            XCTAssertNotEqual(system, SummaryPipeline.planningInstructions)
            XCTAssertFalse(system.contains("Exemple complet, sur une autre session"))
        }
        XCTAssertTrue(LocalLLMProvider.systemInstructions(for: "VERIFY_ACTIONS:\n{}", planning: false).contains("decisions doit être []"))
        XCTAssertTrue(LocalLLMProvider.systemInstructions(for: "VERIFY_DECISIONS:\n{}", planning: false).contains("action_items doit être []"))
        XCTAssertEqual(LocalLLMProvider.systemInstructions(for: "WRITE_TOPIC:\n{\"text\":\"VERIFY_ACTIONS:\"}", planning: false), SummaryPipeline.instructions)
    }
    func testSameCountChangesRequireCitedCorrectionForTextOwnerAndDate() async throws {
        let camille = Speaker(label: "Camille", confirmed: true), jordan = Speaker(label: "Jordan", confirmed: true)
        let recording = Recording(title: "Atelier", speakers: [camille, jordan], segments: [
            .init(start: 0, end: 20, speakerID: camille.id, source: .mic,
                  text: "Camille prépare le guide final pour 2026-10-29. Jordan pourrait aider pour un brouillon le 2026-10-30, mais cela reste à confirmer.")
        ])
        for field in ["text", "owner", "date"] {
            let provider = SameCountChangeProvider(field: field, explain: false)
            do { _ = try await SummaryPipeline.run(recording, provider: provider, model: "fixture"); XCTFail("Unexplained change accepted: \(field)") }
            catch SummaryFailure.unreliableContent {}
        }
        let provider = SameCountChangeProvider(field: "text", explain: true)
        let result = try await SummaryPipeline.run(recording, provider: provider, model: "fixture")
        XCTAssertEqual(result.structured.action_items.count, 1)
        XCTAssertEqual(result.structured.action_items.first?.text, "Préparer le brouillon.")
        XCTAssertFalse(result.structured.markdown.contains("VERSION_FINALE_ACTIVE"))
        let repaired = await provider.repaired
        XCTAssertTrue(repaired)
    }
}

private actor SameCountChangeProvider: LLMProvider {
    let field: String
    let explain: Bool
    var repaired = false
    init(field: String, explain: Bool) { self.field = field; self.explain = explain }
    func generate(prompt: String) async throws -> SummaryContent { throw SummaryFailure.invalidResponse }
    func plan(prompt: String, evidenceIDs: [UUID]) async throws -> SummaryContent { try await generate(prompt: prompt, evidenceIDs: evidenceIDs) }
    func generate(prompt: String, evidenceIDs: [UUID]) async throws -> SummaryContent {
        let id = evidenceIDs[0]
        var action = SummaryAction(text: "Préparer le guide final.", assignee_name: "Camille", assignee_person_id: nil, due_date: "2026-10-29", evidence_segment_ids: [id])
        var result = SummaryContent(overview: "La préparation du guide est discutée.", decisions: [], action_items: [action], key_points: [],
            details: [.init(title: "Guide", text: "VERSION_FINALE_ACTIVE", evidence_segment_ids: [id])])
        if prompt.hasPrefix("VERIFY_ACTIONS:") {
            if field == "text" { action.text = "Préparer le brouillon." }
            if field == "owner" { action.assignee_name = "Jordan" }
            if field == "date" { action.due_date = "2026-10-30" }
            result.action_items = [action]
            result.details = explain ? [.init(title: "Correction", text: "La formulation précédente doit être corrigée.", evidence_segment_ids: [id])] : []
        }
        if prompt.hasPrefix("REPAIR:") {
            repaired = true; result.action_items = []
            result.details = [.init(title: "Guide", text: "La rédaction concerne un brouillon.", evidence_segment_ids: [id])]
        }
        if prompt.hasPrefix("EXECUTIVE:") { result.action_items = []; result.details = [] }
        return result
    }
}
