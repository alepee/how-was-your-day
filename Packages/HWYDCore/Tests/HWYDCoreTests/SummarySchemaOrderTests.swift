import XCTest
@testable import HWYDCore

/// Wire-format checks for the opt-in schema order experiment. No server or model is involved.
final class SummarySchemaOrderTests: XCTestCase {
    private let ids = [UUID(), UUID()]
    private let narrative = ["overview", "details", "decisions", "action_items", "key_points"]
    private let alphabetical = ["action_items", "decisions", "details", "key_points", "overview"]
    private let prefixes = ["EXTRACT:", "ROUTE:", "VERIFY_ACTIONS:", "VERIFY_DECISIONS:", "REPAIR:", "EXECUTIVE:", "WRITE_TOPIC:"]
    private let payload = #"[{"id":"S1","speaker":"Camille","text":"Rendez-vous le 2026-10-29 / ok"},{"id":"S2","speaker":"Jordan","text":"We agree."}]"#

    private func provider(_ order: SummarySchemaOrder) throws -> LocalLLMProvider {
        try LocalLLMProvider(endpoint: URL(string: "http://127.0.0.1:1234/v1")!, model: "fixture", reasoningEffort: "none", schemaOrder: order)
    }
    private func body(_ order: SummarySchemaOrder, prefix: String, planning: Bool, evidence: [UUID]? = nil) throws -> Data {
        let prompt = prefix + "\n" + payload
        let request = try provider(order).makeRequest(prompt: prompt, evidenceIDs: evidence ?? ids,
            system: LocalLLMProvider.systemInstructions(for: prompt, planning: planning), outputTokens: planning ? 3000 : 4000, planning: planning).request
        return try XCTUnwrap(request.httpBody)
    }
    /// Members of a raw JSON object in document order, with each value kept as raw text.
    private func members(_ raw: String) -> [(key: String, value: String)] {
        let text = Array(raw.utf8)
        var result: [(String, String)] = [], depth = 0, index = 0, key: String?, valueStart = 0
        func string(from start: Int) -> (String, Int) {
            var end = start + 1
            while text[end] != UInt8(ascii: "\"") { end += text[end] == UInt8(ascii: "\\") ? 2 : 1 }
            return (String(decoding: text[(start + 1)..<end], as: UTF8.self), end + 1)
        }
        while index < text.count {
            let byte = text[index]
            if byte == UInt8(ascii: "\"") {
                let (value, next) = string(from: index)
                if depth == 1, key == nil, text[next] == UInt8(ascii: ":") { key = value; valueStart = next + 1; index = next + 1; continue }
                index = next; continue
            }
            if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") { depth += 1 }
            if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                if depth == 1, let name = key { result.append((name, String(decoding: text[valueStart..<index], as: UTF8.self))); key = nil }
                depth -= 1
            }
            if byte == UInt8(ascii: ","), depth == 1, let name = key { result.append((name, String(decoding: text[valueStart..<index], as: UTF8.self))); key = nil }
            index += 1
        }
        return result
    }
    private func value(_ raw: String, _ path: [String]) throws -> String {
        var current = raw
        for key in path { current = try XCTUnwrap(members(current).first { $0.key == key }, "Missing \(key)").value }
        return current
    }
    private func rootSchema(_ data: Data) throws -> String { try value(String(decoding: data, as: UTF8.self), ["response_format", "json_schema", "schema"]) }

    func testDefaultBodyIsExistingSortedKeysSerializationAndAlphabetical() throws {
        for prefix in prefixes { for planning in [false, true] {
            let data = try body(.alphabetical, prefix: prefix, planning: planning)
            let object = try JSONSerialization.jsonObject(with: data)
            XCTAssertEqual(data, try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), "\(prefix) planning=\(planning)")
            let schema = try rootSchema(data)
            XCTAssertEqual(members(try value(schema, ["properties"])).map(\.key), alphabetical)
            let required = try JSONSerialization.jsonObject(with: Data(try value(schema, ["required"]).utf8)) as? [String]
            XCTAssertEqual(required, ["overview", "key_points", "decisions", "action_items", "details"])
        } }
        XCTAssertEqual(SummarySchemaOrder.alphabetical, try LocalLLMProvider(endpoint: URL(string: "http://localhost:1/v1")!, model: "m").schemaOrder)
    }
    func testNarrativeFirstOrdersRootPropertiesAndRequiredForEveryStage() throws {
        for prefix in prefixes { for planning in [false, true] {
            let data = try body(.narrativeFirst, prefix: prefix, planning: planning)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
            let schema = try rootSchema(data)
            XCTAssertEqual(members(try value(schema, ["properties"])).map(\.key), narrative, "\(prefix) planning=\(planning)")
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(try value(schema, ["required"]).utf8)) as? [String], narrative)
        } }
    }
    func testOrderChangesOnlyRootPropertyAndRequiredOrder() throws {
        for prefix in prefixes { for planning in [false, true] { for evidence in [ids, []] {
            let sorted = try body(.alphabetical, prefix: prefix, planning: planning, evidence: evidence)
            let ordered = try body(.narrativeFirst, prefix: prefix, planning: planning, evidence: evidence)
            // Semantics: identical once the root `required` array (a set) is compared as a set.
            func normalized(_ data: Data) throws -> NSDictionary {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                var format = try XCTUnwrap(object["response_format"] as? [String: Any])
                var json = try XCTUnwrap(format["json_schema"] as? [String: Any])
                var schema = try XCTUnwrap(json["schema"] as? [String: Any])
                schema["required"] = Set(try XCTUnwrap(schema["required"] as? [String])).sorted()
                json["schema"] = schema; format["json_schema"] = json; object["response_format"] = format
                return object as NSDictionary
            }
            XCTAssertEqual(try normalized(sorted), try normalized(ordered), "\(prefix) planning=\(planning)")
            // Byte level: every root property value, and every other top-level member, is untouched.
            let before = String(decoding: sorted, as: UTF8.self), after = String(decoding: ordered, as: UTF8.self)
            let sortedProperties = members(try value(try rootSchema(sorted), ["properties"])), orderedProperties = members(try value(try rootSchema(ordered), ["properties"]))
            for property in sortedProperties { XCTAssertEqual(orderedProperties.first { $0.key == property.key }?.value, property.value, property.key) }
            for key in ["messages", "model", "temperature", "max_tokens", "stream", "reasoning_effort"] {
                XCTAssertEqual(try value(before, [key]), try value(after, [key]), key)
            }
            let reference = try JSONSerialization.jsonObject(with: ordered) as? [String: Any]
            XCTAssertEqual(reference?["temperature"] as? Int, 0)
            XCTAssertEqual(reference?["stream"] as? Bool, false)
        } } }
    }
    func testSerializerEscapesLikeDefaultAndPreservesArrayOrder() throws {
        let value: [String: Any] = ["b": ["z": 1, "a": [["y": true, "x": NSNull()], 2.5, "é/\"\n"]], "a": ["p": 1, "o": 2]]
        let ordered = try OrderedJSON.data(value, orderedKeys: [(["a"], ["p"])])
        XCTAssertEqual(String(decoding: ordered, as: UTF8.self), #"{"a":{"p":1,"o":2},"b":{"a":[{"x":null,"y":true},2.5,"é\/\"\n"],"z":1}}"#)
        let plain = try OrderedJSON.data(value, orderedKeys: [])
        XCTAssertEqual(plain, try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
    func testBenchmarkIdentityKeepsHistoricalKeyAndSeparatesExperimentalArm() async throws {
        let url = URL(string: "http://127.0.0.1:1234/v1")!
        let historical = url.absoluteString + "|reasoning=none"
        XCTAssertEqual(LocalLLMProvider.benchmarkIdentity(endpoint: url, reasoningEffort: "none", schemaOrder: .alphabetical), historical)
        XCTAssertEqual(LocalLLMProvider.benchmarkIdentity(endpoint: url, reasoningEffort: nil, schemaOrder: .alphabetical), url.absoluteString + "|reasoning=default")
        let experimental = LocalLLMProvider.benchmarkIdentity(endpoint: url, reasoningEffort: "none", schemaOrder: .narrativeFirst)
        XCTAssertNotEqual(experimental, historical)
        XCTAssertEqual(experimental, historical + "|schema-order=narrative-first")
        // The same recording and cache directory never shares checkpoints across arms.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = Recording(title: "Atelier", segments: [.init(start: 0, end: 10, speakerID: nil, source: .mic, text: "Nous discutons des accès temporaires.")])
        let counter = CountingProvider()
        for identity in [historical, historical, experimental, experimental] {
            _ = try await SummaryPipeline.run(recording, provider: counter, model: "fixture", cacheDirectory: directory, providerIdentity: identity)
        }
        let calls = await counter.calls
        XCTAssertEqual(calls, 4, "Two arms, two stages each, each arm cached on its second run")
    }
}

private actor CountingProvider: LLMProvider {
    var calls = 0
    func generate(prompt: String) async throws -> SummaryContent { throw SummaryFailure.invalidResponse }
    func generate(prompt: String, evidenceIDs: [UUID]) async throws -> SummaryContent {
        calls += 1
        var result = SummaryContent(overview: "Un atelier sur les accès.", decisions: [], action_items: [])
        result.details = [.init(title: "Accès", text: "Le groupe étudie les accès.", evidence_segment_ids: Array(evidenceIDs.prefix(1)))]
        return result
    }
}
