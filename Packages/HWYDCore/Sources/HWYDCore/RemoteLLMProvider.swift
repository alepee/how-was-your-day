import Foundation

/// One summary stage, independent of the wire protocol: system text with its output contract,
/// user input with `S<n>` references, the JSON schema and the reference map back to segment UUIDs.
struct SummaryStageRequest {
    let system: String
    let input: String
    let schema: [String: Any]
    let references: [String: String]

    init(prompt: String, evidenceIDs: [UUID], system: String, planning: Bool,
         intermediateLanguage: SummaryIntermediateLanguage, schemaOrder: SummarySchemaOrder = .alphabetical) throws {
        let references = Dictionary(uniqueKeysWithValues: evidenceIDs.enumerated().map { ("S\($0.offset + 1)", $0.element.uuidString) })
        var input = prompt
        for (reference, id) in references { input = input.replacingOccurrences(of: id, with: reference) }
        var evidenceItem: [String: Any] = ["type": "string"]
        if !references.isEmpty { evidenceItem["enum"] = references.keys.sorted() }
        let routing = prompt.hasPrefix("ROUTE:")
        let executive = prompt.hasPrefix("EXECUTIVE:")
        let verification = prompt.hasPrefix("VERIFY_")
        let verifyActions = prompt.hasPrefix("VERIFY_ACTIONS:")
        let verifyDecisions = prompt.hasPrefix("VERIFY_DECISIONS:")
        let repair = prompt.hasPrefix("REPAIR:")
        let evidence: [String: Any] = ["type": "array", "minItems": 1, "maxItems": planning ? 64 : 3, "items": evidenceItem]
        let datePattern = try NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}\b"#)
        let dates = Array(Set(datePattern.matches(in: input, range: NSRange(input.startIndex..., in: input)).compactMap { Range($0.range, in: input).map { String(input[$0]) } })).sorted()
        let dateSchema: [String: Any] = dates.isEmpty ? ["type": "null"] : ["anyOf": [["type": "string", "enum": dates], ["type": "null"]]]
        var names = Set<String>()
        func collectNames(_ value: Any) {
            if let entries = value as? [Any] { entries.forEach(collectNames) }
            if let object = value as? [String: Any] {
                for key in ["speaker", "assignee_name"] {
                    if let name = object[key] as? String, name != "Voix non identifiée" { names.insert(name) }
                }
                object.values.forEach(collectNames)
            }
        }
        if let newline = input.firstIndex(of: "\n"), let data = String(input[input.index(after: newline)...]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) { collectNames(object) }
        let assigneeSchema: [String: Any] = names.isEmpty ? ["type": "null"] : ["anyOf": [["type": "string", "enum": names.sorted()], ["type": "null"]]]
        let claimEvidence: [String: Any] = ["type": "array", "minItems": 1, "maxItems": 3, "items": evidenceItem]
        let topic: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["title", "text", "evidence_segment_ids"], "properties": ["title": ["type": "string"], "text": ["type": "string"], "evidence_segment_ids": evidence]]
        let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": schemaOrder == .alphabetical ? ["overview", "key_points", "decisions", "action_items", "details"] : SummarySchemaOrder.narrativeFirstFields, "properties": [
            "overview": ["type": "string"],
            "key_points": ["type": "array", "maxItems": routing || verification || repair ? 0 : 4, "items": topic],
            "details": ["type": "array", "maxItems": executive ? 0 : (repair ? 1 : (verification ? 4 : (planning ? 8 : 16))), "items": topic],
            "decisions": ["type": "array", "maxItems": routing || executive || repair || verifyActions ? 0 : 32, "items": ["type": "object", "additionalProperties": false, "required": ["text", "evidence_segment_ids"], "properties": ["text": ["type": "string"], "evidence_segment_ids": claimEvidence]]],
            "action_items": ["type": "array", "maxItems": routing || executive || repair || verifyDecisions ? 0 : 64, "items": ["type": "object", "additionalProperties": false, "required": ["text", "assignee_name", "assignee_person_id", "due_date", "evidence_segment_ids"], "properties": ["text": ["type": "string"], "assignee_name": assigneeSchema, "assignee_person_id": ["type": "null"], "due_date": dateSchema, "evidence_segment_ids": claimEvidence]]]
        ]]
        // Only the intermediate stages follow the configured language. Final writing stays French.
        let intermediateStage = prompt.hasPrefix("EXTRACT:") || routing || verification
        let contract = LocalLLMProvider.outputContract(planning: planning, routing: routing, executive: executive,
                                                       verification: verification, verifyActions: verifyActions, verifyDecisions: verifyDecisions, repair: repair,
                                                       language: intermediateStage ? intermediateLanguage : .french)
        self.system = system + "\n\n" + contract
        self.input = input
        self.schema = schema
        self.references = references
    }

    /// Schema without array size constraints, which hosted structured-output engines reject or ignore.
    /// `enforceArrayLimits` applies the removed upper bounds to the response instead.
    static func portable(_ schema: Any, keepEvidenceEnum: Bool = true) -> Any {
        if let object = schema as? [String: Any] {
            var output: [String: Any] = [:]
            for (key, value) in object where key != "minItems" && key != "maxItems" {
                if key == "evidence_segment_ids", !keepEvidenceEnum, var array = value as? [String: Any] {
                    array["items"] = ["type": "string"]
                    output[key] = portable(array, keepEvidenceEnum: keepEvidenceEnum)
                } else {
                    output[key] = portable(value, keepEvidenceEnum: keepEvidenceEnum)
                }
            }
            return output
        }
        if let array = schema as? [Any] { return array.map { portable($0, keepEvidenceEnum: keepEvidenceEnum) } }
        return schema
    }

    /// Truncates arrays to the `maxItems` of the original schema, as constrained decoding would.
    /// Lower bounds are left to `SummaryPipeline.validate`.
    static func enforceArrayLimits(_ value: Any, schema: [String: Any]) -> Any {
        if let object = value as? [String: Any], let properties = schema["properties"] as? [String: Any] {
            var output = object
            for (key, child) in object {
                if let childSchema = properties[key] as? [String: Any] { output[key] = enforceArrayLimits(child, schema: childSchema) }
            }
            return output
        }
        if let array = value as? [Any] {
            let limited = (schema["maxItems"] as? Int).map { Array(array.prefix($0)) } ?? array
            guard let items = schema["items"] as? [String: Any] else { return limited }
            return limited.map { enforceArrayLimits($0, schema: items) }
        }
        return value
    }

    /// Parses the model's JSON text and translates `S<n>` references back to segment UUIDs.
    static func decode(_ content: String, references: [String: String], limits: [String: Any]? = nil) throws -> SummaryContent {
        guard let json = content.data(using: .utf8) else { throw SummaryFailure.invalidResponse }
        do {
            guard let parsed = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw SummaryFailure.invalidContent("réponse qui n’est pas un objet JSON") }
            guard var output = (limits.map { enforceArrayLimits(parsed, schema: $0) } ?? parsed) as? [String: Any] else { throw SummaryFailure.invalidResponse }
            if !references.isEmpty {
                if var overview = output["overview"] as? String {
                    for reference in references.keys { overview = overview.replacingOccurrences(of: "[" + reference + "]", with: "") }
                    output["overview"] = overview.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                for key in ["decisions", "action_items", "key_points", "details"] {
                    guard var entries = output[key] as? [[String: Any]] else { throw SummaryFailure.invalidContent("champ \(key) absent ou mal formé") }
                    for index in entries.indices {
                        guard let ids = entries[index]["evidence_segment_ids"] as? [String] else { throw SummaryFailure.invalidContent("références absentes dans \(key)") }
                        entries[index]["evidence_segment_ids"] = try ids.map { id in
                            guard let uuid = references[id] else { throw SummaryFailure.invalidContent("référence inconnue « \(id.prefix(40)) » dans \(key)") }
                            return uuid
                        }
                    }
                    // Some models repeat bracketed citations in prose despite the schema.
                    // Remove only known reference markers; the validated evidence array is retained.
                    for index in entries.indices {
                        for field in ["text", "title"] {
                            if var text = entries[index][field] as? String {
                                for reference in references.keys { text = text.replacingOccurrences(of: "[" + reference + "]", with: "") }
                                entries[index][field] = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                    }
                    output[key] = entries
                }
            }
            do { return try JSONDecoder().decode(SummaryContent.self, from: JSONSerialization.data(withJSONObject: output)) }
            catch { throw SummaryFailure.invalidContent("structure JSON différente du schéma") }
        } catch let failure as SummaryFailure { throw failure }
        catch { throw SummaryFailure.invalidResponse }
    }
}

/// Where summaries are generated. `.local` keeps the transcript on this Mac; hosted APIs receive it
/// with each summary; `.agent` hands it to the user's own ACP agent, which also uses its own context.
public enum SummaryService: String, CaseIterable, Identifiable, Sendable {
    case local, agent, mistral, openai, anthropic, gemini
    public var id: String { rawValue }
    /// A hosted API called with the user's key.
    public var isRemote: Bool { ![.local, .agent].contains(self) }
    public var displayName: String {
        switch self {
        case .local: "Serveur local"
        case .agent: "Agent (ACP)"
        case .mistral: "Mistral"
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .gemini: "Google Gemini"
        }
    }
    /// Editable starting point; the user can enter any model their account offers.
    public var defaultModel: String {
        switch self {
        case .local, .agent: ""
        case .mistral: "mistral-medium-latest"
        case .openai: "gpt-5-mini"
        case .anthropic: "claude-opus-5-5"
        case .gemini: "gemini-flash-latest"
        }
    }
    public var baseURL: URL? {
        switch self {
        case .local, .agent: nil
        case .mistral: URL(string: "https://api.mistral.ai/v1")
        case .openai: URL(string: "https://api.openai.com/v1")
        case .anthropic: URL(string: "https://api.anthropic.com/v1")
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")
        }
    }
}

/// Hosted provider. Mistral, OpenAI and Gemini use their OpenAI-compatible chat completions
/// endpoint; Anthropic uses the Messages API. Every stage keeps the local prompts and schema;
/// array size limits are enforced on the response because hosted engines do not all accept them.
public struct RemoteLLMProvider: LLMProvider {
    public let service: SummaryService
    public let model: String
    let apiKey: String
    let baseURL: URL
    public let intermediateLanguage: SummaryIntermediateLanguage
    static let outputTokens = 16_000
    /// Hosted models have far larger contexts than local servers (128k tokens and more), so a
    /// typical one-hour session fits one extraction window and takes the two-request path.
    /// About 200,000 characters stay well below 128k tokens, with room for output.
    public var requestCharacterCeiling: Int { 200_000 }
    public var extractionWindowCharacters: Int { 120_000 }
    public var retriesRejectedOutput: Bool { true }
    /// Above this count, segment references are not enumerated in the schema: hosted engines cap
    /// enum sizes. Unknown references are still rejected when the response is decoded.
    static let evidenceEnumLimit = 200
    static let anthropicVersion = "2026-10-21"

    public init(service: SummaryService, model: String, apiKey: String, baseURL: URL? = nil,
                intermediateLanguage: SummaryIntermediateLanguage = .french) throws {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard service.isRemote, let url = baseURL ?? service.baseURL else { throw SummaryFailure.invalidEndpoint }
        guard !apiKey.isEmpty else { throw SummaryFailure.apiKeyMissing(service.displayName) }
        guard !model.isEmpty else { throw SummaryFailure.modelMissing(service.displayName) }
        self.service = service; self.model = model; self.apiKey = apiKey; self.baseURL = url
        self.intermediateLanguage = intermediateLanguage
    }
    /// Stored in the summary provenance and the stage cache key. Never contains the key.
    public var identity: String { service.rawValue + "|" + baseURL.absoluteString }

    public func generate(prompt: String) async throws -> SummaryContent { try await generate(prompt: prompt, evidenceIDs: []) }
    public func plan(prompt: String, evidenceIDs: [UUID]) async throws -> SummaryContent {
        try await send(prompt: prompt, evidenceIDs: evidenceIDs, planning: true)
    }
    public func generate(prompt: String, evidenceIDs: [UUID]) async throws -> SummaryContent {
        try await send(prompt: prompt, evidenceIDs: evidenceIDs, planning: false)
    }

    func makeRequest(prompt: String, evidenceIDs: [UUID], planning: Bool) throws -> (request: URLRequest, stage: SummaryStageRequest) {
        let system = LocalLLMProvider.systemInstructions(for: prompt, planning: planning, language: intermediateLanguage)
        let stage = try SummaryStageRequest(prompt: prompt, evidenceIDs: evidenceIDs, system: system, planning: planning,
                                            intermediateLanguage: intermediateLanguage)
        let schema = SummaryStageRequest.portable(stage.schema, keepEvidenceEnum: stage.references.count <= Self.evidenceEnumLimit)
        var request: URLRequest
        var body: [String: Any]
        switch service {
        case .anthropic:
            request = URLRequest(url: baseURL.appendingPathComponent("messages"))
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
            // API version 2026-10-21 rejects sampling parameters; thinking stays at the model default.
            body = ["model": model, "max_tokens": Self.outputTokens, "system": stage.system,
                    "messages": [["role": "user", "content": stage.input]],
                    "output_config": ["format": ["type": "json_schema", "schema": schema]]]
        default:
            request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
            request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
            body = ["model": model, "stream": false,
                    "messages": [["role": "system", "content": stage.system], ["role": "user", "content": stage.input]],
                    "response_format": ["type": "json_schema", "json_schema": ["name": "session_summary", "strict": true, "schema": schema]]]
            switch service {
            case .openai:
                // Reasoning models reject temperature and max_tokens; reasoning counts toward the limit.
                body["max_completion_tokens"] = Self.outputTokens; body["reasoning_effort"] = "low"
            case .gemini:
                body["max_tokens"] = Self.outputTokens; body["temperature"] = 0; body["reasoning_effort"] = "low"
            default:
                body["max_tokens"] = Self.outputTokens; body["temperature"] = 0
            }
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return (request, stage)
    }

    private func send(prompt: String, evidenceIDs: [UUID], planning: Bool) async throws -> SummaryContent {
        let (request, stage) = try makeRequest(prompt: prompt, evidenceIDs: evidenceIDs, planning: planning)
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 600; config.timeoutIntervalForResource = 900
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 2_000_000 else { throw SummaryFailure.invalidResponse }
        guard http.statusCode == 200 else {
            throw SummaryFailure.remoteRejected(service: service.displayName, status: http.statusCode, detail: Self.errorDetail(data))
        }
        let content = try Self.content(of: data, service: service)
        return try SummaryStageRequest.decode(content, references: stage.references, limits: stage.schema)
    }

    /// Extracts the JSON text of a successful response, rejecting truncated or refused outputs.
    static func content(of data: Data, service: SummaryService) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SummaryFailure.invalidResponse }
        if service == .anthropic {
            switch object["stop_reason"] as? String {
            case "max_tokens": throw SummaryFailure.outputTruncated
            case "refusal": throw SummaryFailure.refused(service.displayName)
            default: break
            }
            guard let blocks = object["content"] as? [[String: Any]],
                  let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else { throw SummaryFailure.invalidResponse }
            return text
        }
        guard let choice = (object["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] else { throw SummaryFailure.invalidResponse }
        if choice["finish_reason"] as? String == "length" { throw SummaryFailure.outputTruncated }
        if message["refusal"] as? String != nil || choice["finish_reason"] as? String == "content_filter" { throw SummaryFailure.refused(service.displayName) }
        guard let text = message["content"] as? String else { throw SummaryFailure.invalidResponse }
        return text
    }

    /// Short provider message for the user. Providers mask keys in their own error text.
    static func errorDetail(_ data: Data) -> String {
        let object = try? JSONSerialization.jsonObject(with: data)
        let error = ((object as? [[String: Any]])?.first ?? object as? [String: Any])?["error"]
        let message = (error as? [String: Any])?["message"] as? String ?? error as? String
            ?? (object as? [String: Any])?["message"] as? String ?? ""
        let line = message.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
    }
}

/// Lists the models a hosted provider offers for this key. Doubles as a key check: a rejected
/// key throws `SummaryFailure.remoteRejected` with status 401 or 403.
public enum SummaryModelCatalog {
    public static func models(service: SummaryService, apiKey: String, baseURL: URL? = nil) async throws -> [String] {
        let request = try makeRequest(service: service, apiKey: apiKey, baseURL: baseURL)
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 5_000_000 else { throw SummaryFailure.invalidResponse }
        guard http.statusCode == 200 else {
            throw SummaryFailure.remoteRejected(service: service.displayName, status: http.statusCode, detail: RemoteLLMProvider.errorDetail(data))
        }
        return try parse(data, service: service)
    }

    static func makeRequest(service: SummaryService, apiKey: String, baseURL: URL? = nil) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard service.isRemote, var url = baseURL ?? service.baseURL else { throw SummaryFailure.invalidEndpoint }
        guard !key.isEmpty else { throw SummaryFailure.apiKeyMissing(service.displayName) }
        var request: URLRequest
        switch service {
        case .anthropic:
            url = url.appendingPathComponent("models")
            request = URLRequest(url: URL(string: url.absoluteString + "?limit=1000")!)
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(RemoteLLMProvider.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        case .gemini:
            // The native endpoint reports which models support generation; the key goes in a header, not the URL.
            url = url.deletingLastPathComponent().appendingPathComponent("models")
            request = URLRequest(url: URL(string: url.absoluteString + "?pageSize=1000")!)
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        default:
            request = URLRequest(url: url.appendingPathComponent("models"))
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Keeps text generation models only, deduplicated and sorted alphabetically.
    static func parse(_ data: Data, service: SummaryService) throws -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SummaryFailure.invalidResponse }
        var ids: [String] = []
        switch service {
        case .gemini:
            for model in object["models"] as? [[String: Any]] ?? [] {
                guard let name = model["name"] as? String,
                      (model["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true else { continue }
                let id = name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
                if id.hasPrefix("gemini"), !id.contains("embedding"), !id.contains("image"), !id.contains("tts") { ids.append(id) }
            }
        case .mistral:
            for model in object["data"] as? [[String: Any]] ?? [] {
                guard let id = model["id"] as? String else { continue }
                let capabilities = model["capabilities"] as? [String: Any]
                if capabilities?["completion_chat"] as? Bool ?? true, !id.contains("embed"), !id.contains("moderation"), !id.contains("ocr") { ids.append(id) }
            }
        case .openai:
            let excluded = ["embedding", "tts", "whisper", "dall-e", "image", "audio", "realtime", "moderation", "transcribe", "search", "instruct", "codex", "computer-use", "babbage", "davinci"]
            for model in object["data"] as? [[String: Any]] ?? [] {
                guard let id = model["id"] as? String else { continue }
                let chat = id.hasPrefix("gpt-") || id.hasPrefix("chatgpt-") || id.range(of: #"^o\d"#, options: .regularExpression) != nil
                if chat, !excluded.contains(where: id.contains) { ids.append(id) }
            }
        default:
            ids = (object["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        }
        guard !ids.isEmpty || object["data"] != nil || object["models"] != nil else { throw SummaryFailure.invalidResponse }
        return Array(Set(ids)).sorted()
    }
}
