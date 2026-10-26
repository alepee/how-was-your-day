import Foundation
import Darwin
import GRDB

/// Bootstrap UI schema. Production pipeline migrations remain a separate milestone.
public actor SessionStore {
    /// Lightweight polling for external MCP changes; do not decode transcripts on every tick.
    public func recordingRevisions() throws -> [UUID: Int] {
        try database.read { db in
            var result: [UUID: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, revision FROM ui_recordings") {
                if let id = UUID(uuidString: row["id"]) { result[id] = row["revision"] }
            }
            return result
        }
    }
    let database: DatabaseQueue
    public nonisolated let directory: URL
    public init(directory: URL, readOnly: Bool = false, migrate: Bool = true) throws {
        self.directory = directory
        if readOnly || !migrate {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("hwyd.sqlite").path) else { throw IntegrationError("STORE_NOT_INITIALIZED") }
        } else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.readonly = readOnly
        database = try DatabaseQueue(path: directory.appendingPathComponent("hwyd.sqlite").path, configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("ui_v001_sessions") { db in
            try db.execute(sql: """
                CREATE TABLE ui_recordings (
                    id TEXT PRIMARY KEY NOT NULL,
                    started_at REAL NOT NULL,
                    revision INTEGER NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE INDEX ui_recordings_date ON ui_recordings(started_at DESC, id);
                CREATE TABLE ui_recording_versions (
                    recording_id TEXT NOT NULL REFERENCES ui_recordings(id) ON DELETE CASCADE,
                    revision INTEGER NOT NULL,
                    payload BLOB NOT NULL,
                    PRIMARY KEY (recording_id, revision)
                );
                """)
        }
        migrator.registerMigration("ui_v002_people") { db in
            try db.execute(sql: "CREATE TABLE voice_people(id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
        }
        migrator.registerMigration("ui_v003_integrations") { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE recording_search USING fts5(recording_id UNINDEXED, artifact UNINDEXED, text, tokenize='unicode61 remove_diacritics 2');
                CREATE TABLE integration_settings(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
                CREATE TABLE mutation_receipts(id TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE export_outbox(recording_id TEXT NOT NULL, revision INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(recording_id, revision));
                CREATE TABLE export_deletions(recording_id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL);
                CREATE TABLE integration_sequence(id INTEGER PRIMARY KEY CHECK(id=1), seq INTEGER NOT NULL);
                INSERT INTO integration_sequence VALUES (1,0);
                """)
            for data in try Data.fetchAll(db, sql: "SELECT payload FROM ui_recordings") {
                let item = try JSONDecoder().decode(Recording.self, from: data)
                try Self.index(item, db: db)
            }
        }
        if !readOnly && migrate { try migrator.migrate(database) }
        else {
            let names = try database.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
            guard Set(names) == Set(["ui_v001_sessions", "ui_v002_people", "ui_v003_integrations"]) else { throw IntegrationError("SCHEMA_MISMATCH") }
        }
    }
    public func all() throws -> [Recording] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM ui_recordings ORDER BY started_at DESC, id")
                .map { try JSONDecoder().decode(Recording.self, from: $0) }
        }
    }
    @discardableResult public func save(_ recording: Recording) throws -> Recording {
        try database.write { db in try Self.persist(recording, db: db) }
    }
    static func persist(_ recording: Recording, db: Database) throws -> Recording {
        let oldData = try Data.fetchOne(db, sql: "SELECT payload FROM ui_recordings WHERE id=?", arguments: [recording.id.uuidString])
        let old = try oldData.map { try JSONDecoder().decode(Recording.self, from: $0) }
        if let old, old.revision != recording.revision { throw StoreError.conflict }
        var updated = recording; updated.revision += 1
        if updated.summary == nil { updated.summaryProvenance = nil }
        updated.notesVersion = max(1, (old?.notesVersion ?? 0) + ((old?.notes != updated.notes || old?.noteEntries != updated.noteEntries) ? 1 : 0))
        updated.summaryVersion = updated.summary == nil ? nil : (old?.summaryVersion ?? 0) + (old?.summary != updated.summary ? 1 : 0)
        let payload = try JSONEncoder().encode(updated)
        try db.execute(sql: "INSERT INTO ui_recordings(id,started_at,revision,payload) VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,payload=excluded.payload", arguments: [updated.id.uuidString, updated.startedAt.timeIntervalSince1970, updated.revision, payload])
        try db.execute(sql: "INSERT INTO ui_recording_versions VALUES (?,?,?)", arguments: [updated.id.uuidString, updated.revision, payload])
        try index(updated, db: db)
        try db.execute(sql: "UPDATE integration_sequence SET seq=seq+1")
        if updated.state != .recording {
            try db.execute(sql: "INSERT INTO export_outbox VALUES (?,?,?)", arguments: [updated.id.uuidString, updated.revision, payload])
        }
        return updated
    }
    static func index(_ recording: Recording, db: Database) throws {
        try db.execute(sql: "DELETE FROM recording_search WHERE recording_id=?", arguments: [recording.id.uuidString])
        for (artifact, text) in [("title", recording.title), ("notes", SessionExporter.artifact(recording, "notes")), ("transcript", SessionExporter.artifact(recording, "transcript")), ("summary", recording.summary ?? "")] {
            try db.execute(sql: "INSERT INTO recording_search(recording_id,artifact,text) VALUES (?,?,?)", arguments: [recording.id.uuidString, artifact, text])
        }
    }
    public func remove(_ id: UUID) throws {
        try database.write { db in
            if let revision = try Int.fetchOne(db, sql: "SELECT revision FROM ui_recordings WHERE id=?", arguments: [id.uuidString]) {
                try db.execute(sql: "INSERT OR REPLACE INTO export_deletions VALUES (?,?)", arguments: [id.uuidString, revision + 1])
            }
            try db.execute(sql: "DELETE FROM ui_recordings WHERE id = ?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM recording_search WHERE recording_id=?", arguments: [id.uuidString])
            try db.execute(sql: "DELETE FROM export_outbox WHERE recording_id=?", arguments: [id.uuidString])
            try db.execute(sql: "UPDATE integration_sequence SET seq=seq+1")
        }
    }
    public func recoverInterrupted() throws -> Int {
        let lock = open(directory.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw StoreError.invalidPath }
        defer { close(lock) }
        // A second app must never recover files that the first app is still writing.
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return 0 }
        defer { flock(lock, LOCK_UN) }
        let interrupted = try all().filter { $0.state == .recording }
        for var item in interrupted {
            item.state = .interrupted
            item.audioChunks = try AudioRecovery.recover(in: directory, recordingID: item.id)
            item.duration = item.audioChunks.map { $0.start + $0.duration }.max() ?? item.duration
            _ = try save(item)
        }
        return interrupted.count
    }
    public func versions(for id: UUID) throws -> [Recording] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM ui_recording_versions WHERE recording_id=? ORDER BY revision", arguments: [id.uuidString])
                .map { try JSONDecoder().decode(Recording.self, from: $0) }
        }
    }
    public nonisolated func audioURL(for chunk: AudioChunk) throws -> URL {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(chunk.relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/"), !chunk.relativePath.hasPrefix("/") else { throw StoreError.invalidPath }
        return url
    }
}
