import Foundation
import GRDB
import CryptoKit

public struct IntegrationError: LocalizedError, Sendable {
    public var code: String
    public init(_ code: String) { self.code = code }
    public var errorDescription: String? { code }
}
public struct SearchHit: Sendable {
    public var recordingID: UUID
    public var artifact: String
    public var snippet: String
    public var rank: Double
}
public struct MutationReceipt: Codable, Sendable {
    public var id: UUID
    public var revision: Int
    public var request_id: UUID
    public var identity_enrollment = "not_performed"
    public var export_state = "pending"
}
extension SessionStore {
    public func setting(_ key: String) throws -> String? {
        try database.read { try String.fetchOne($0, sql: "SELECT value FROM integration_settings WHERE key=?", arguments: [key]) }
    }
    public func setSetting(_ key: String, value: String) throws {
        try database.write { try $0.execute(sql: "INSERT INTO integration_settings VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [key, value]) }
    }
    public func sequence() throws -> Int { try database.read { try Int.fetchOne($0, sql: "SELECT seq FROM integration_sequence") ?? 0 } }
    public func recording(_ id: UUID, revision: Int? = nil) throws -> Recording {
        try database.read { db in
            let data: Data?
            if let revision { data = try Data.fetchOne(db, sql: "SELECT payload FROM ui_recording_versions WHERE recording_id=? AND revision=?", arguments: [id.uuidString, revision]) }
            else { data = try Data.fetchOne(db, sql: "SELECT payload FROM ui_recordings WHERE id=?", arguments: [id.uuidString]) }
            guard let data else { throw IntegrationError("NOT_FOUND") }
            return try JSONDecoder().decode(Recording.self, from: data)
        }
    }
    public func search(_ query: String) throws -> [SearchHit] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        guard !tokens.isEmpty, query.count <= 500 else { throw IntegrationError("INVALID_ARGUMENTS") }
        return try database.read { db in
            try Row.fetchAll(db, sql: "SELECT recording_id,artifact,snippet(recording_search,2,'','', '…',32) AS excerpt,bm25(recording_search) AS rank FROM recording_search WHERE recording_search MATCH ? ORDER BY rank,recording_id,artifact", arguments: [tokens.joined(separator: " AND ")]).compactMap { row in
                guard let id = UUID(uuidString: row["recording_id"]) else { return nil }
                return SearchHit(recordingID: id, artifact: row["artifact"], snippet: row["excerpt"], rank: row["rank"])
            }
        }
    }
    public func mutate(id: UUID, expectedRevision: Int, requestID: UUID, notes: String? = nil, speaker: UUID? = nil, personID: UUID? = nil) throws -> MutationReceipt {
        let input: [String: String] = ["id": id.uuidString, "revision": String(expectedRevision), "notes": notes ?? "", "operation": notes == nil ? "rename" : "notes", "speaker": speaker?.uuidString ?? "", "person": personID?.uuidString ?? ""]
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]), as: UTF8.self)
        let hash = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
        return try database.write { db in
            guard try String.fetchOne(db, sql: "SELECT value FROM integration_settings WHERE key='mcp_writes_enabled'") == "true" else { throw IntegrationError("WRITE_DISABLED") }
            if let row = try Row.fetchOne(db, sql: "SELECT fingerprint,payload FROM mutation_receipts WHERE id=?", arguments: [requestID.uuidString]) {
                guard row["fingerprint"] as String == hash else { throw IntegrationError("IDEMPOTENCY_CONFLICT") }
                return try JSONDecoder().decode(MutationReceipt.self, from: row["payload"])
            }
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM ui_recordings WHERE id=?", arguments: [id.uuidString]) else { throw IntegrationError("NOT_FOUND") }
            var item = try JSONDecoder().decode(Recording.self, from: data)
            guard item.revision == expectedRevision else { throw IntegrationError("VERSION_CONFLICT") }
            guard item.state != .recording else { throw IntegrationError("STORE_BUSY") }
            if let notes { guard notes.count <= 200_000 else { throw IntegrationError("INVALID_ARGUMENTS") }; item.notes = notes }
            else {
                guard let speaker, let personID, let index = item.speakers.firstIndex(where: { $0.id == speaker }),
                      let personData = try Data.fetchOne(db, sql: "SELECT payload FROM voice_people WHERE id=?", arguments: [personID.uuidString]) else { throw IntegrationError("NOT_FOUND") }
                let person = try JSONDecoder().decode(VoicePerson.self, from: personData)
                guard !person.opposed else { throw IntegrationError("PERSON_OPPOSED") }
                item.speakers[index].label = person.name; item.speakers[index].confirmed = true
                item.speakers[index].personID = personID; item.speakers[index].proposedIdentity = nil
                item.transcriptVersion += 1; item.summary = nil
            }
            item = try Self.persist(item, db: db)
            let receipt = MutationReceipt(id: id, revision: item.revision, request_id: requestID)
            try db.execute(sql: "INSERT INTO mutation_receipts VALUES (?,?,?)", arguments: [requestID.uuidString, hash, try JSONEncoder().encode(receipt)])
            return receipt
        }
    }
    public func publishPending() throws {
        guard let root = try setting("export_directory"), !root.isEmpty else { return }
        let deleted: [(String, Int)] = try database.read { db in try Row.fetchAll(db, sql: "SELECT recording_id,revision FROM export_deletions").map { ($0["recording_id"], $0["revision"]) } }
        for (id, revision) in deleted {
            try SessionExporter.delete(id: id.lowercased(), revision: revision, from: URL(fileURLWithPath: root))
            try database.write { try $0.execute(sql: "DELETE FROM export_deletions WHERE recording_id=?", arguments: [id]) }
        }
        let pending = try database.read { try Data.fetchAll($0, sql: "SELECT payload FROM export_outbox ORDER BY recording_id,revision") }
        for data in pending {
            let item = try JSONDecoder().decode(Recording.self, from: data)
            try SessionExporter.export(item, to: URL(fileURLWithPath: root))
            try database.write { try $0.execute(sql: "DELETE FROM export_outbox WHERE recording_id=? AND revision=?", arguments: [item.id.uuidString, item.revision]) }
        }
    }
}
