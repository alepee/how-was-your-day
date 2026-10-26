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
        XCTAssertTrue(prompts.last!.contains(recording.segments[0].text))
        XCTAssertTrue(prompts.last!.contains("topic_map"))
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
        let provider = try LocalLLMProvider(endpoint: endpoint, model: model)
        let started = Date()
        let result = try await SummaryPipeline.run(recording, provider: provider, model: model, inputCharacterLimit: 242_144,
            cacheDirectory: directory.appendingPathComponent("cache"), providerIdentity: endpoint.absoluteString) { progress in
                print("BENCHMARK \(progress.stage) \(progress.completed)/\(progress.total) cached=\(progress.cached)")
            }
        try JSONEncoder().encode(result).write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        try result.structured.markdown.write(to: directory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        try "Elapsed seconds: \(Date().timeIntervalSince(started))\nModel: \(model)\n".write(to: directory.appendingPathComponent("timing.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(result.structured.details?.isEmpty ?? true)
    }
}
