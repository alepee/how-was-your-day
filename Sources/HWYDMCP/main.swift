import Foundation
import CryptoKit
import MCP
import HWYDCore

func json(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) }
func value(_ object: Any) throws -> Value { try JSONDecoder().decode(Value.self, from: Data(json(object).utf8)) }
func nullable<T>(_ x: T?) -> Any { x.map { $0 as Any } ?? NSNull() }

// Schemas are shipped with the executable and also used to validate incoming arguments.
func validate(_ input: [String: Any], schema: [String: Any]) throws {
    let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
    guard Set(input.keys).isSubset(of: Set(properties.keys)), (schema["required"] as? [String] ?? []).allSatisfy({ input[$0] != nil }) else { throw IntegrationError("INVALID_ARGUMENTS") }
    for (key, x) in input {
        let spec = properties[key]!
        if spec["type"] as? String == "string" {
            guard let s = x as? String, s.count >= (spec["minLength"] as? Int ?? 0), s.count <= (spec["maxLength"] as? Int ?? 200000) else { throw IntegrationError("INVALID_ARGUMENTS") }
            if let values = spec["enum"] as? [String], !values.contains(s) { throw IntegrationError("INVALID_ARGUMENTS") }
            if spec["format"] as? String == "uuid", UUID(uuidString: s) == nil { throw IntegrationError("INVALID_ARGUMENTS") }
            if spec["format"] as? String == "date-time", ISO8601DateFormatter().date(from: s) == nil { throw IntegrationError("INVALID_ARGUMENTS") }
        } else if spec["type"] as? String == "integer" {
            guard x as? Int != nil, let n = x as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.rounded() == n.doubleValue, n.doubleValue >= Double(spec["minimum"] as? Int ?? 0), n.doubleValue <= Double(spec["maximum"] as? Int ?? Int.max) else { throw IntegrationError("INVALID_ARGUMENTS") }
        }
    }
}
import CoreFoundation

actor MCPService {
    let store: SessionStore
    let writes: Bool
    let schemaData: Data
    let cursorKey = SymmetricKey(size: .bits256)
    struct Cursor: Codable { var method: String; var filter: String; var sequence: Int; var offset: Int; var expires: Double }
    init(store: SessionStore, writes: Bool, schemaData: Data) { self.store = store; self.writes = writes; self.schemaData = schemaData }
    func metadata(_ r: Recording) -> [String: Any] {
        ["id": r.id.uuidString, "revision": r.revision, "title": r.title, "kind": r.kind.rawValue, "started_at": r.startedAt.ISO8601Format(), "duration_us": Int64(r.duration * 1e6), "status": r.state == .recording ? "capturing" : r.transcriptState == .ready ? "complete" : "partial", "participants": r.participants.map { ["id": ($0.personID ?? $0.id).uuidString, "name": $0.label, "alias": NSNull(), "status": "named"] as [String: Any] }]
    }
    func cursor(_ method: String, _ hash: String, _ seq: Int, _ offset: Int) throws -> String {
        let data = try JSONEncoder().encode(Cursor(method: method, filter: hash, sequence: seq, offset: offset, expires: Date().timeIntervalSince1970 + 900))
        return data.base64EncodedString() + "." + Data(HMAC<SHA256>.authenticationCode(for: data, using: cursorKey)).base64EncodedString()
    }
    func offset(_ input: [String: Any], _ method: String, _ hash: String, _ seq: Int) throws -> Int {
        guard let raw = input["cursor"] as? String else { return 0 }
        let parts = raw.split(separator: ".")
        guard parts.count == 2, let data = Data(base64Encoded: String(parts[0])), let mac = Data(base64Encoded: String(parts[1])), HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: data, using: cursorKey), let c = try? JSONDecoder().decode(Cursor.self, from: data), c.method == method, c.filter == hash, c.offset >= 0 else { throw IntegrationError("INVALID_CURSOR") }
        guard c.sequence == seq, c.expires > Date().timeIntervalSince1970 else { throw IntegrationError("CURSOR_STALE") }
        return c.offset
    }
    func call(_ method: String, arguments: String) async throws -> String {
        let schemas = try JSONSerialization.jsonObject(with: schemaData) as! [String: Any]
        let tools = schemas["tools"] as! [String: [String: Any]]
        guard let schema = tools[method]?["inputSchema"] as? [String: Any], let input = try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { throw IntegrationError("INVALID_ARGUMENTS") }
        try validate(input, schema: schema)
        if ["set_notes", "rename_speaker"].contains(method) {
            guard writes else { throw IntegrationError("WRITE_DISABLED") }
            let receipt = try await store.mutate(id: UUID(uuidString: input["id"] as! String)!, expectedRevision: input["expected_revision"] as! Int, requestID: UUID(uuidString: input["request_id"] as! String)!, notes: input["markdown"] as? String, speaker: (input["speaker"] as? String).flatMap(UUID.init(uuidString:)), personID: (input["person"] as? String).flatMap(UUID.init(uuidString:)))
            // The receipt remains durable even if publishing must be retried by the app.
            try? await store.publishPending()
            return String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        }
        let seq = try await store.sequence()
        let hash = SHA256.hash(data: Data(try json(input.filter { $0.key != "cursor" }).utf8)).map { String(format: "%02x", $0) }.joined()
        let start = try offset(input, method, hash, seq)
        let limit = input["limit"] as? Int ?? 50
        var result: [String: Any]
        func matches(_ r: Recording) -> Bool {
            if let kind = input["kind"] as? String, r.kind.rawValue != kind { return false }
            if let since = input["since"] as? String, let date = ISO8601DateFormatter().date(from: since), r.startedAt < date { return false }
            if let person = input["participant"] as? String, !r.speakers.contains(where: { $0.confirmed && ($0.personID ?? $0.id).uuidString.lowercased() == person.lowercased() }) { return false }
            return true
        }
        switch method {
        case "get_recording":
            let r = try await store.recording(UUID(uuidString: input["id"] as! String)!, revision: input["revision"] as? Int)
            let include = input["include"] as? String ?? "all"
            let names = ["transcript", "summary", "notes"].filter { include == "all" || $0 == include }
            let maximum = input["max_chars"] as? Int ?? 50000
            var position = 0, consumed = 0, artifacts: [String: Any] = [:]
            let total = names.reduce(0) { $0 + SessionExporter.artifact(r, $1).count }
            guard start <= total else { throw IntegrationError("INVALID_CURSOR") }
            for name in names {
                let text = SessionExporter.artifact(r, name), count = text.count
                let localStart = max(0, start - position)
                if localStart <= count, consumed < maximum {
                    let chunk = String(text.dropFirst(localStart).prefix(maximum - consumed)); consumed += chunk.count
                    let available = name != "summary" || r.summary != nil
                    let version = name == "transcript" ? r.transcriptVersion : name == "notes" ? r.notesVersion : r.summaryVersion
                    artifacts[name] = ["status": available ? "ready" : "disabled", "version": available ? nullable(version) : NSNull(), "markdown": available ? chunk as Any : NSNull()]
                }
                position += count
            }
            let next = start + consumed
            result = ["recording": metadata(r), "artifacts": artifacts, "next_cursor": next < total ? try cursor(method, hash, seq, next) as Any : NSNull(), "truncated": next < total]
        case "list_recordings", "search", "get_participants":
            var items: [[String: Any]] = []
            if method == "get_participants" {
                items = try await store.people().sorted { $0.id.uuidString < $1.id.uuidString }.map { ["id": $0.id.uuidString, "name": $0.name, "alias": NSNull(), "status": "named"] }
            } else {
                let recordings = try await store.all().filter(matches)
                if method == "list_recordings" { items = recordings.map(metadata) }
                else {
                    let byID = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
                    items = try await store.search(input["query"] as! String).compactMap { hit in
                        guard let r = byID[hit.recordingID] else { return nil }
                        return ["recording_id": r.id.uuidString, "revision": r.revision, "artifact": hit.artifact, "entity_id": r.id.uuidString, "snippet": hit.snippet, "rank": hit.rank, "resource_uri": "hwyd://recording/\(r.id.uuidString)/\(hit.artifact == "title" ? "transcript" : hit.artifact).md"]
                    }
                }
            }
            guard start <= items.count else { throw IntegrationError("INVALID_CURSOR") }
            let end = min(items.count, start + limit)
            result = ["items": Array(items[start..<end]), "next_cursor": end < items.count ? try cursor(method, hash, seq, end) as Any : NSNull(), "snapshot_seq": seq]
        default: throw IntegrationError("INVALID_ARGUMENTS")
        }
        guard try await store.sequence() == seq else { throw IntegrationError("CURSOR_STALE") }
        return try json(result)
    }
    func resource(_ uri: String) async throws -> String {
        guard let url = URLComponents(string: uri), url.scheme == "hwyd", url.host == "recording", url.query == nil, url.fragment == nil, url.user == nil, url.port == nil else { throw IntegrationError("INVALID_RESOURCE_URI") }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, let id = UUID(uuidString: String(parts[1])), ["transcript.md", "summary.md", "notes.md"].contains(String(parts[2])), !uri.contains("%") else { throw IntegrationError("INVALID_RESOURCE_URI") }
        let r = try await store.recording(id)
        let text = SessionExporter.artifact(r, String(parts[2].dropLast(3)))
        guard text.utf8.count <= 1_048_576 else { throw IntegrationError("RESOURCE_TOO_LARGE") }
        return text
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") {
    print("hwyd-mcp [--store /absolute/path] [--allow-write | --read-only]\nTransport stdio. Écritures soumises aussi au réglage de l’app.")
} else {
    do {
        var path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HWYD").path
        var index = 0
        while index < args.count {
            if args[index] == "--store", index + 1 < args.count { index += 1; path = args[index] }
            else if !["--allow-write", "--read-only"].contains(args[index]) { throw IntegrationError("INVALID_ARGUMENTS") }
            index += 1
        }
        guard path.hasPrefix("/") else { throw IntegrationError("INVALID_ARGUMENTS") }
        let requestedWrites = args.contains("--allow-write") && !args.contains("--read-only")
        let store = try SessionStore(directory: URL(fileURLWithPath: path), readOnly: !requestedWrites, migrate: false)
        let writeSetting = try await store.setting("mcp_writes_enabled")
        let writes = requestedWrites && writeSetting == "true"
        let schemaData = try Data(contentsOf: Bundle.module.url(forResource: "tools", withExtension: "json")!)
        let schemas = try JSONSerialization.jsonObject(with: schemaData) as! [String: Any]
        let definitions = schemas["$defs"]!
        let toolSchemas = schemas["tools"] as! [String: [String: Any]]
        let toolList = try toolSchemas.keys.sorted().filter { writes || !["set_notes", "rename_speaker"].contains($0) }.map { name in
            var input = toolSchemas[name]!["inputSchema"] as! [String: Any]; input["$defs"] = definitions
            var output = toolSchemas[name]!["outputSchema"] as! [String: Any]; output["$defs"] = definitions
            return try Tool(name: name, description: name, inputSchema: value(input), annotations: .init(readOnlyHint: !["set_notes", "rename_speaker"].contains(name), destructiveHint: false, idempotentHint: true, openWorldHint: false), outputSchema: value(output))
        }
        let service = MCPService(store: store, writes: writes, schemaData: schemaData)
        let server = Server(name: "hwyd", version: "0.2.0", capabilities: .init(resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: toolList) }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let arguments = String(decoding: try JSONEncoder().encode(params.arguments ?? [:]), as: UTF8.self)
                let text = try await service.call(params.name, arguments: arguments)
                return try .init(content: [.text(text)], structuredContent: try JSONDecoder().decode(Value.self, from: Data(text.utf8)), isError: false)
            } catch {
                let code = (error as? IntegrationError)?.code ?? "INTERNAL_ERROR"
                return .init(content: [.text(try json(["code": code, "message": code, "retryable": ["STORE_BUSY", "CURSOR_STALE"].contains(code), "current_revision": NSNull()]))], isError: true)
            }
        }
        await server.withMethodHandler(ListResources.self) { _ in .init(resources: []) }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            .init(templates: ["transcript", "summary", "notes"].map { Resource.Template(uriTemplate: "hwyd://recording/{id}/\($0).md", name: $0, mimeType: "text/markdown") })
        }
        await server.withMethodHandler(ReadResource.self) { params in
            .init(contents: [.text(try await service.resource(params.uri), uri: params.uri, mimeType: "text/markdown")])
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    } catch {
        FileHandle.standardError.write(Data(("hwyd-mcp: \(error.localizedDescription)\n").utf8))
        exit(1)
    }
}
