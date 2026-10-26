import XCTest
@testable import HWYDCore

/// Request-level checks for the opt-in English intermediate variant. No server or model is involved.
final class SummaryIntermediateLanguageTests: XCTestCase {
    private let endpoint = URL(string: "http://127.0.0.1:1234/v1")!
    private let ids = [UUID(), UUID()]
    private let intermediate = ["EXTRACT:", "ROUTE:", "VERIFY_ACTIONS:", "VERIFY_DECISIONS:"]
    private let finalStages = ["WRITE_TOPIC:", "EXECUTIVE:", "REPAIR:"]
    private let payload = #"[{"id":"S1","speaker":"Camille","text":"Rendez-vous le 2026-10-29 / ok"},{"id":"S2","speaker":"Jordan","text":"We agree."}]"#
    private var frenchCharacters: CharacterSet { CharacterSet(charactersIn: "àâäçéèêëîïôöùûüÿœÀÂÄÇÉÈÊËÎÏÔÖÙÛÜŒ«»’") }
    private let frenchWords = ["Conserve", "recopie", " doit ", "Tu ", "Regroupe", "paroles", "fiches", "Comprends", "Cartographie", "Sinon ", "Vérifie", "Applique", "Réponds", "Écris", "Rédige"]

    private func planning(_ prefix: String) -> Bool { prefix == "EXTRACT:" || prefix == "ROUTE:" }
    private func provider(_ language: SummaryIntermediateLanguage?, order: SummarySchemaOrder = .alphabetical) throws -> LocalLLMProvider {
        if let language { return try LocalLLMProvider(endpoint: endpoint, model: "fixture", reasoningEffort: "none", schemaOrder: order, intermediateLanguage: language) }
        return try LocalLLMProvider(endpoint: endpoint, model: "fixture", reasoningEffort: "none", schemaOrder: order)
    }
    private func request(_ provider: LocalLLMProvider, _ prefix: String) throws -> Data {
        let prompt = prefix + "\n" + payload, planning = planning(prefix)
        let built = try provider.makeRequest(prompt: prompt, evidenceIDs: ids, system: provider.stageInstructions(for: prompt, planning: planning),
                                             outputTokens: planning ? 3000 : 4000, planning: planning)
        return try XCTUnwrap(built.request.httpBody)
    }
    private func body(_ provider: LocalLLMProvider, _ prefix: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: request(provider, prefix)) as? [String: Any])
    }
    private func messages(_ body: [String: Any]) throws -> (system: String, user: String) {
        let list = try XCTUnwrap(body["messages"] as? [[String: Any]])
        return (try XCTUnwrap(list[0]["content"] as? String), try XCTUnwrap(list[1]["content"] as? String))
    }
    /// The JSON shape and limits of a contract: lines that do not depend on the wording language.
    private func shape(_ contract: String) -> [String] {
        contract.split(separator: "\n").map(String.init).filter { $0.hasPrefix("{") || $0.hasPrefix("Topic =") || $0.hasPrefix("Decision =") || $0.hasPrefix("Action =") }
    }

    func testOptionParsingDefaultsToFrenchAndRejectsUnknownValuesClearly() throws {
        XCTAssertEqual(try SummaryIntermediateLanguage.option(nil), .french)
        XCTAssertEqual(try SummaryIntermediateLanguage.option("french"), .french)
        XCTAssertEqual(try SummaryIntermediateLanguage.option("english"), .english)
        for value in ["", "English", "en", "fr", " english", "french ", "fr-FR"] {
            XCTAssertThrowsError(try SummaryIntermediateLanguage.option(value), value) { error in
                XCTAssertEqual(error as? SummaryIntermediateLanguage.InvalidOption, SummaryIntermediateLanguage.InvalidOption(value: value))
                XCTAssertTrue(error.localizedDescription.contains("Unknown intermediate language \"\(value)\""), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("expected french or english"), error.localizedDescription)
            }
        }
        XCTAssertEqual(SummaryIntermediateLanguage.environmentKey, "HWYD_LIVE_LLM_INTERMEDIATE_LANGUAGE")
        XCTAssertEqual(try SummaryIntermediateLanguage.option(environment: [:]), .french)
        XCTAssertEqual(try SummaryIntermediateLanguage.option(environment: ["HWYD_LIVE_LLM_SCHEMA_ORDER": "narrative-first"]), .french)
        XCTAssertEqual(try SummaryIntermediateLanguage.option(environment: ["HWYD_LIVE_LLM_INTERMEDIATE_LANGUAGE": "english"]), .english)
        XCTAssertThrowsError(try SummaryIntermediateLanguage.option(environment: ["HWYD_LIVE_LLM_INTERMEDIATE_LANGUAGE": "klingon"]))
    }
    func testDefaultProviderIsFrenchAndRequestsAreByteIdenticalToExplicitFrench() throws {
        XCTAssertEqual(try provider(nil).intermediateLanguage, .french)
        for prefix in intermediate + finalStages {
            XCTAssertEqual(try request(provider(nil), prefix), try request(provider(.french), prefix), prefix)
            for planningFlag in [false, true] {
                let prompt = prefix + "\n{}"
                XCTAssertEqual(LocalLLMProvider.systemInstructions(for: prompt, planning: planningFlag),
                               LocalLLMProvider.systemInstructions(for: prompt, planning: planningFlag, language: .french), prefix)
            }
        }
        XCTAssertEqual(LocalLLMProvider.outputContract(planning: true), LocalLLMProvider.outputContract(planning: true, language: .french))
        // Anchors on the shipped wording, so an accidental edit of the French path is caught.
        XCTAssertTrue(LocalLLMProvider.systemInstructions(for: "EXTRACT:\n{}", planning: true).hasPrefix("Cartographie cette conversation en français."))
        XCTAssertTrue(LocalLLMProvider.systemInstructions(for: "ROUTE:\n{}", planning: true).contains("Tu classes des fiches thématiques"))
        XCTAssertTrue(LocalLLMProvider.systemInstructions(for: "VERIFY_ACTIONS:\n{}", planning: false).contains("Tu es un vérificateur de candidats"))
        XCTAssertTrue(LocalLLMProvider.outputContract(planning: true).hasPrefix("FORMAT DE SORTIE OBLIGATOIRE"))
    }
    func testEnglishIntermediateStagesCarryNoFrenchDirective() throws {
        let english = try provider(.english), french = try provider(.french)
        for prefix in intermediate {
            let text = try messages(try body(english, prefix)).system
            XCTAssertNil(text.rangeOfCharacter(from: frenchCharacters), "\(prefix): \(text)")
            for word in frenchWords { XCTAssertFalse(text.contains(word), "\(prefix) contains \(word)") }
            XCTAssertTrue(text.contains("English"), prefix)
            XCTAssertTrue(text.contains("MANDATORY OUTPUT FORMAT"), prefix)
            XCTAssertFalse(text.contains("FORMAT DE SORTIE"), prefix)
            // Schema field names and the stage rules are preserved.
            for field in ["overview", "key_points", "decisions", "action_items", "details", "evidence_segment_ids", "assignee_name", "assignee_person_id", "due_date", "YYYY-MM-DD"] {
                XCTAssertTrue(text.contains(field), "\(prefix) lost \(field)")
            }
            XCTAssertNotEqual(text, try messages(try body(french, prefix)).system)
            XCTAssertEqual(shape(text), shape(try messages(try body(french, prefix)).system), "JSON shape and limits must not change: \(prefix)")
        }
        XCTAssertTrue(try messages(body(english, "VERIFY_ACTIONS:")).system.contains("decisions must be []"))
        XCTAssertTrue(try messages(body(english, "VERIFY_DECISIONS:")).system.contains("action_items must be []"))
        XCTAssertTrue(try messages(body(english, "ROUTE:")).system.contains("decisions=[], action_items=[], key_points=[]"))
    }
    func testEnglishPlanningInstructionsKeepEveryRuleAndFieldOfTheFrenchOnes() {
        XCTAssertEqual(SummaryPipeline.planningInstructionsEnglish.split(separator: "\n").count, SummaryPipeline.planningInstructions.split(separator: "\n").count)
        XCTAssertNil(SummaryPipeline.planningInstructionsEnglish.rangeOfCharacter(from: frenchCharacters))
        for token in ["overview", "details", "decisions", "action_items", "key_points", "evidence_segment_ids", "assignee_person_id = null", "due_date = null", "YYYY-MM-DD", "echo_suspect", "JSON"] {
            XCTAssertTrue(SummaryPipeline.planningInstructions.contains(token), "French lost \(token)")
            XCTAssertTrue(SummaryPipeline.planningInstructionsEnglish.contains(token), "English lost \(token)")
        }
        XCTAssertEqual(LocalLLMProvider.systemInstructions(for: "EXTRACT:\n{}", planning: true, language: .english), SummaryPipeline.planningInstructionsEnglish)
    }
    func testSchemaBudgetsAndUserPayloadAreIndependentOfLanguage() throws {
        let english = try provider(.english), french = try provider(.french)
        for prefix in intermediate + finalStages {
            var before = try body(french, prefix), after = try body(english, prefix)
            // Source payload, with references and dates: the user message is not translated.
            XCTAssertEqual(try messages(before).user, try messages(after).user, prefix)
            XCTAssertTrue(try messages(after).user.contains("Rendez-vous le 2026-10-29 / ok"), prefix)
            before["messages"] = nil; after["messages"] = nil
            XCTAssertEqual(before as NSDictionary, after as NSDictionary, "Schema, budgets and options must not change: \(prefix)")
        }
        for prefix in finalStages {
            XCTAssertEqual(try request(english, prefix), try request(french, prefix), "Final stage \(prefix) must be unchanged")
        }
    }
    func testFinalStagesStayFrenchAndSourceTextCannotSelectInstructions() throws {
        let english = try provider(.english)
        for prefix in finalStages {
            let text = try messages(try body(english, prefix)).system
            XCTAssertEqual(text, try messages(try body(provider(.french), prefix)).system, prefix)
            XCTAssertTrue(text.contains("français"), prefix)
            XCTAssertTrue(text.contains("FORMAT DE SORTIE OBLIGATOIRE"), prefix)
        }
        XCTAssertEqual(english.stageInstructions(for: "WRITE_TOPIC:\n{\"text\":\"VERIFY_ACTIONS:\"}", planning: false), SummaryPipeline.instructions)
        XCTAssertEqual(english.stageInstructions(for: "WRITE_TOPIC:\n{\"text\":\"ROUTE:\"}", planning: false), SummaryPipeline.instructions)
    }
    func testBenchmarkIdentityKeepsHistoricalKeysAndNeverCollidesAcrossArms() {
        let base = endpoint.absoluteString + "|reasoning=none"
        func identity(_ order: SummarySchemaOrder, _ language: SummaryIntermediateLanguage) -> String {
            LocalLLMProvider.benchmarkIdentity(endpoint: endpoint, reasoningEffort: "none", schemaOrder: order, intermediateLanguage: language)
        }
        XCTAssertEqual(identity(.alphabetical, .french), base)
        XCTAssertEqual(identity(.narrativeFirst, .french), base + "|schema-order=narrative-first")
        XCTAssertEqual(identity(.alphabetical, .english), base + "|intermediate-language=english")
        XCTAssertEqual(identity(.narrativeFirst, .english), base + "|schema-order=narrative-first|intermediate-language=english")
        XCTAssertEqual(LocalLLMProvider.benchmarkIdentity(endpoint: endpoint, reasoningEffort: "none", schemaOrder: .alphabetical), base)
        XCTAssertEqual(LocalLLMProvider.benchmarkIdentity(endpoint: endpoint, reasoningEffort: nil, schemaOrder: .alphabetical), endpoint.absoluteString + "|reasoning=default")
        let all = SummarySchemaOrder.allCases.flatMap { order in SummaryIntermediateLanguage.allCases.map { identity(order, $0) } }
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(Set(all).count, 4)
    }
    func testCheckpointsAreNotSharedAcrossLanguagesEvenWithTheSameProviderIdentity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = Recording(title: "Atelier", segments: [.init(start: 0, end: 10, speakerID: nil, source: .mic, text: "Nous discutons des accès temporaires.")])
        let counter = LanguageCounter()
        var hashes: [SummaryIntermediateLanguage: String] = [:], versions: [SummaryIntermediateLanguage: String] = [:]
        // A caller that forgets to vary providerIdentity must still not mix languages.
        for language in [SummaryIntermediateLanguage.french, .english, .french, .english] {
            let result = try await SummaryPipeline.run(recording, provider: LanguageCountingProvider(language: language, counter: counter), model: "fixture",
                                                       cacheDirectory: directory, providerIdentity: "shared-identity")
            hashes[language] = result.promptHash; versions[language] = result.promptVersion
        }
        let calls = await counter.calls
        XCTAssertEqual(calls, 4, "Two languages, two stages each, each cached on its second run")
        XCTAssertNotEqual(hashes[.french], hashes[.english])
        XCTAssertEqual(versions[.french], "summary-v7-grounded-writing")
        XCTAssertEqual(versions[.english], "summary-v7-grounded-writing+intermediate-english")
        XCTAssertEqual(hashes[.english]?.count, 64)
    }
}

private actor LanguageCounter {
    var calls = 0
    func record() { calls += 1 }
}

private struct LanguageCountingProvider: LLMProvider {
    let intermediateLanguage: SummaryIntermediateLanguage
    let counter: LanguageCounter
    init(language: SummaryIntermediateLanguage = .french, counter: LanguageCounter = LanguageCounter()) { self.intermediateLanguage = language; self.counter = counter }
    func generate(prompt: String) async throws -> SummaryContent { throw SummaryFailure.invalidResponse }
    func generate(prompt: String, evidenceIDs: [UUID]) async throws -> SummaryContent {
        await counter.record()
        var result = SummaryContent(overview: "Un atelier sur les accès.", decisions: [], action_items: [])
        result.details = [.init(title: "Accès", text: "Le groupe étudie les accès.", evidence_segment_ids: Array(evidenceIDs.prefix(1)))]
        return result
    }
}
