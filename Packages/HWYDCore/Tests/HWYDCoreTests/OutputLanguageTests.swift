import XCTest
@testable import HWYDCore

/// The user's language preference: per-app language list, English summaries, documents in the summary's language.
final class OutputLanguageTests: XCTestCase {
    private let endpoint = URL(string: "http://127.0.0.1:1234/v1")!
    private let ids = [UUID(), UUID()]
    private let payload = #"[{"id":"S1","speaker":"Camille","text":"On valide."},{"id":"S2","speaker":"Jordan","text":"We agree."}]"#

    func testAppLanguageReadsAndWritesThePerAppLanguageList() {
        XCTAssertEqual(AppLanguage(appleLanguages: nil), .system)
        XCTAssertEqual(AppLanguage(appleLanguages: ["fr-FR", "en"]), .french)
        XCTAssertEqual(AppLanguage(appleLanguages: ["en-GB"]), .english)
        XCTAssertEqual(AppLanguage(appleLanguages: ["de"]), .system, "A language HWYD is not translated into is left to macOS")
        XCTAssertNil(AppLanguage.system.appleLanguages)
        XCTAssertEqual(AppLanguage.english.appleLanguages, ["en"])
        let settings = InMemorySettings()
        settings.set(AppLanguage.french.appleLanguages, for: .appleLanguages)
        XCTAssertEqual(settings.storedValue(forKey: "AppleLanguages") as? [String], ["fr"])
        settings.set(AppLanguage.system.appleLanguages, for: .appleLanguages)
        XCTAssertFalse(settings.contains(.appleLanguages))
    }

    func testWithoutTheCatalogHWYDWritesInFrench() {
        XCTAssertEqual(SummaryLanguage.current, .french)
        XCTAssertEqual(SummaryLanguage.current.voiceLabel(2), "Voix 2")
    }

    func testEnglishOutputRunsEveryStageInEnglish() throws {
        let provider = try LocalLLMProvider(endpoint: endpoint, model: "fixture", outputLanguage: .english)
        XCTAssertEqual(provider.intermediateLanguage, .english)
        for prefix in ["EXTRACT:", "ROUTE:", "VERIFY_ACTIONS:", "WRITE_TOPIC:", "EXECUTIVE:", "REPAIR:"] {
            let prompt = prefix + "\n" + payload, planning = prefix == "EXTRACT:" || prefix == "ROUTE:"
            let built = try provider.makeRequest(prompt: prompt, evidenceIDs: ids, system: provider.stageInstructions(for: prompt, planning: planning),
                                                 outputTokens: 3000, planning: planning)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(built.request.httpBody)) as? [String: Any])
            let system = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? String)
            XCTAssertTrue(system.contains("English"), prefix)
            XCTAssertTrue(system.contains("MANDATORY OUTPUT FORMAT"), prefix)
            XCTAssertFalse(system.contains("Écris en français") || system.contains("FORMAT DE SORTIE"), prefix)
        }
    }

    func testFrenchOutputKeepsTheFrenchFinalStages() throws {
        let provider = try LocalLLMProvider(endpoint: endpoint, model: "fixture", intermediateLanguage: .english)
        XCTAssertEqual(provider.outputLanguage, .french)
        let system = provider.stageInstructions(for: "WRITE_TOPIC:\n" + payload, planning: false)
        XCTAssertEqual(system, SummaryPipeline.instructions)
    }

    func testEnglishSummariesHaveTheirOwnIdentityAndRecordTheirLanguage() async throws {
        let recording = Recording(title: "Workshop", segments: [.init(start: 0, end: 10, speakerID: nil, source: .mic, text: "We discuss temporary access.")])
        let prompts = PromptLog()
        let english = try await SummaryPipeline.run(recording, provider: RecordingProvider(outputLanguage: .english, prompts: prompts), model: "fixture")
        let french = try await SummaryPipeline.run(recording, provider: RecordingProvider(outputLanguage: .french, prompts: PromptLog()), model: "fixture")
        XCTAssertEqual(english.promptVersion, "summary-v7-grounded-writing+english")
        XCTAssertEqual(english.language, "en")
        XCTAssertEqual(french.promptVersion, "summary-v7-grounded-writing")
        XCTAssertEqual(french.language, "fr")
        XCTAssertNotEqual(english.promptHash, french.promptHash)
        let sent = await prompts.values
        XCTAssertTrue(sent.contains { $0.hasPrefix("WRITE_TOPIC: write this theme") })
        XCTAssertTrue(sent.allSatisfy { !$0.contains("Voix non identifiée") })
        XCTAssertTrue(english.markdown.hasPrefix("## Overview"))
    }

    func testAgentPromptFollowsTheLanguage() throws {
        let recording = Recording(title: "Workshop", segments: [.init(start: 0, end: 10, speakerID: nil, source: .mic, text: "Hello.")])
        let english = try AgentSummaryTask.prompt(recording, language: .english)
        XCTAssertTrue(english.contains("Write in English"))
        XCTAssertTrue(english.contains("Unidentified voice"))
        XCTAssertTrue(try AgentSummaryTask.prompt(recording).contains("Écris en français"))
        XCTAssertNotEqual(AgentSummaryTask.promptHash(for: .english), AgentSummaryTask.promptHash(for: .french))
        XCTAssertEqual(AgentSummaryTask.promptVersion(for: .french), AgentSummaryTask.promptVersion)
    }

    func testDocumentsUseTheLanguageOfTheSummary() throws {
        var item = DemoContent.recordings(language: .english)[0]; item.isDemo = false
        XCTAssertEqual(item.title, "The next chapter")
        XCTAssertEqual(item.speakers.last?.label, "Voice 3")
        let summary = try XCTUnwrap(item.summary)
        XCTAssertTrue(summary.contains("## Next steps\n\n- Camille: Prepare two first-launch flows."))
        XCTAssertEqual(SummaryExport.sections(item), [.overview, .keyPoints, .decisions, .actions, .details])
        XCTAssertFalse(SummaryExport.keeping([.decisions], of: summary).contains("## Details"))
        let markdown = try XCTUnwrap(SummaryExport.markdown(item))
        XCTAssertTrue(markdown.contains("_Summary generated by fixture on "))
        XCTAssertTrue(SummaryExport.fileName(item).hasSuffix(" - summary"))
        // A French summary keeps French words whatever the preference.
        let french = DemoContent.recordings(language: .french)[0]
        XCTAssertTrue(try XCTUnwrap(SummaryExport.markdown(french)).contains("## Étapes suivantes"))
    }

    func testSummariesFromEarlierVersionsReadAsFrench() throws {
        let old = #"{"provider":"p","model":"m","promptVersion":"v","promptHash":"h","generatedAt":0,"transcriptVersion":1,"inputHash":"i","structured":{"overview":"o","decisions":[],"action_items":[]}}"#
        let provenance = try JSONDecoder().decode(SummaryProvenance.self, from: Data(old.utf8))
        XCTAssertNil(provenance.language)
        XCTAssertEqual(provenance.summaryLanguage, .french)
        XCTAssertTrue(provenance.markdown.hasPrefix("## Résumé"))
    }
}

private actor PromptLog {
    var values: [String] = []
    func append(_ prompt: String) { values.append(prompt) }
}

private struct RecordingProvider: LLMProvider {
    let outputLanguage: SummaryLanguage
    let prompts: PromptLog
    func generate(prompt: String) async throws -> SummaryContent { throw SummaryFailure.invalidResponse }
    func generate(prompt: String, evidenceIDs: [UUID]) async throws -> SummaryContent {
        await prompts.append(prompt)
        var result = SummaryContent(overview: "A workshop about access.", decisions: [], action_items: [])
        result.details = [.init(title: "Access", text: "The group studies access.", evidence_segment_ids: Array(evidenceIDs.prefix(1)))]
        return result
    }
}
