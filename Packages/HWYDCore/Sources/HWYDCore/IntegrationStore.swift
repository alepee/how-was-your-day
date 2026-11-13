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
/// Settings shared by the app, `hwyd-mcp` and the export publisher, stored in SQLite so that a
/// helper reads them without the app. Their keys are declared here only.
enum IntegrationSetting: String {
    /// "true" lets an MCP client started with `--allow-write` change notes and voice names.
    case mcpWritesEnabled = "mcp_writes_enabled"
    /// Folder where saved sessions are published; empty or missing means no publication.
    case exportDirectory = "export_directory"

    static func value(_ key: Self, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM integration_settings WHERE key=?", arguments: [key.rawValue])
    }
}
extension SessionStore {
    private func setting(_ key: IntegrationSetting) throws -> String? {
        try database.read { try IntegrationSetting.value(key, in: $0) }
    }
    private func setSetting(_ key: IntegrationSetting, value: String) throws {
        try database.write { try $0.execute(sql: "INSERT INTO integration_settings VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [key.rawValue, value]) }
    }
    /// Whether MCP clients may write. Off unless the user turned it on.
    public func mcpWritesEnabled() throws -> Bool { try setting(.mcpWritesEnabled) == "true" }
    public func setMCPWritesEnabled(_ enabled: Bool) throws { try setSetting(.mcpWritesEnabled, value: enabled ? "true" : "false") }
    /// The publication folder, nil when none is chosen.
    public func exportDirectory() throws -> URL? {
        guard let path = try setting(.exportDirectory), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    public func setExportDirectory(_ directory: URL) throws { try setSetting(.exportDirectory, value: directory.path) }
    public func sequence() throws -> Int { try database.read { try Int.fetchOne($0, sql: "SELECT seq FROM integration_sequence") ?? 0 } }
    public func recording(_ id: UUID) throws -> Recording { try recording(id, revision: nil) }
    /// The session at `revision`, from its history, or the current one when `revision` is nil.
    public func recording(_ id: UUID, revision: Int?) throws -> Recording {
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
            guard try IntegrationSetting.value(.mcpWritesEnabled, in: db) == "true" else { throw IntegrationError("WRITE_DISABLED") }
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
                guard let speaker, let personID,
                      let personData = try Data.fetchOne(db, sql: "SELECT payload FROM voice_people WHERE id=?", arguments: [personID.uuidString]) else { throw IntegrationError("NOT_FOUND") }
                // The same confirmation as in the app: a rename, never an enrollment.
                do { try item.linkSpeaker(speaker, to: try JSONDecoder().decode(VoicePerson.self, from: personData)) }
                catch VoiceReviewError.opposedPerson { throw IntegrationError("PERSON_OPPOSED") }
                catch StoreError.notFound { throw IntegrationError("NOT_FOUND") }
                catch StoreError.invalidName { throw IntegrationError("INVALID_ARGUMENTS") }
            }
            item = try Self.persist(item, db: db)
            let receipt = MutationReceipt(id: id, revision: item.revision, request_id: requestID)
            try db.execute(sql: "INSERT INTO mutation_receipts VALUES (?,?,?)", arguments: [requestID.uuidString, hash, try JSONEncoder().encode(receipt)])
            return receipt
        }
    }
    /// The export outbox: withdrawals of deleted sessions, then committed revisions in commit order.
    /// Publication itself is the `ExportPublisher`'s.
    public func pendingExports() throws -> [ExportOutboxEntry] {
        try database.read { db in
            let withdrawals = try Row.fetchAll(db, sql: "SELECT recording_id,revision FROM export_deletions ORDER BY recording_id").compactMap { row -> ExportOutboxEntry? in
                UUID(uuidString: row["recording_id"]).map { .withdraw(id: $0, revision: row["revision"]) }
            }
            let revisions = try Data.fetchAll(db, sql: "SELECT payload FROM export_outbox ORDER BY recording_id,revision")
                .map { ExportOutboxEntry.publish(try JSONDecoder().decode(Recording.self, from: $0)) }
            return withdrawals + revisions
        }
    }
    public func acknowledgeExport(_ entry: ExportOutboxEntry) throws {
        try database.write { db in
            switch entry {
            case .withdraw(let id, _): try db.execute(sql: "DELETE FROM export_deletions WHERE recording_id=?", arguments: [id.uuidString])
            case .publish(let item): try db.execute(sql: "DELETE FROM export_outbox WHERE recording_id=? AND revision=?", arguments: [item.id.uuidString, item.revision])
            }
        }
    }
}
extension SessionStore {
    /// Transitional: drains the outbox into the configured folder. Callers move to `SessionLibrary`.
    public func publishPending() async throws {
        guard let directory = try exportDirectory() else { return }
        try await ExportOutbox.drain(self, to: FolderExportPublisher(directory: directory))
    }
}
