import Foundation

/// What deleting a session took away. Each thing deletion comes to own (its files, for one)
/// adds a field here, so callers of `RecordingRepository.remove` keep their shape.
public struct RecordingRemoval: Sendable {
    /// The session as it was stored, nil when no session had this id.
    public var removed: Recording?
    /// The session's files the adapter removed or failed to remove, nil when the adapter keeps no files.
    public var files: SessionFiles.Report?
    public init(removed: Recording?, files: SessionFiles.Report? = nil) { self.removed = removed; self.files = files }
}

/// One entry of the export outbox: a committed revision to publish, or a deleted session to
/// withdraw. Every commit of a sealed session and every deletion leaves one, in the same
/// transaction, so nothing committed is missed by the publisher.
public enum ExportOutboxEntry: Equatable, Sendable {
    case publish(Recording)
    case withdraw(id: UUID, revision: Int)
}

/// Where sessions are stored. Writers use optimistic concurrency: `save` succeeds only when the
/// stored revision is the one the caller read, and every commit, by any process (the app,
/// `hwyd-mcp`), moves `sequence()`.
///
/// Adapters: `SessionStore` (GRDB, shared with `hwyd-mcp` and `hwyd-pipeline`) and
/// `InMemoryRecordingRepository` (tests).
public protocol RecordingRepository: Sendable {
    /// Every session, newest first.
    func all() async throws -> [Recording]
    /// The stored session. Throws `IntegrationError("NOT_FOUND")` when there is none.
    func recording(_ id: UUID) async throws -> Recording
    /// The stored revision of every session, without decoding them.
    func revisions() async throws -> [UUID: Int]
    /// Commits `recording` read at `recording.revision` and returns what was stored: the next
    /// revision and the versions the store keeps. Throws `StoreError.conflict` when another writer
    /// committed first, and `StoreError.notFound` when the session was deleted since it was read.
    @discardableResult func save(_ recording: Recording) async throws -> Recording
    /// Deletes the session, queues its withdrawal from the published exports, then removes the files it owns.
    /// Throws `StoreError.capturing` while the session is recording.
    @discardableResult func remove(_ id: UUID) async throws -> RecordingRemoval
    /// Removes files left by sessions deleted earlier. Returns nil when the adapter keeps no files or a helper job is running.
    /// Never call it on an empty library: a missing database is not evidence that its sessions were deleted.
    func removeOrphanFiles(now: Date) async throws -> SessionFiles.Report?
    /// Marks sessions left recording by a crash as interrupted, with the audio found on disk.
    /// Returns how many were found.
    func recoverInterrupted() async throws -> Int
    /// Grows with every commit and deletion, by any process.
    func sequence() async throws -> Int
    /// What the publisher has not taken yet: withdrawals first, then revisions in commit order.
    func pendingExports() async throws -> [ExportOutboxEntry]
    /// Removes a published entry from the outbox.
    func acknowledgeExport(_ entry: ExportOutboxEntry) async throws
}

extension Recording {
    /// The session as a store commits it over `stored`: the next revision, a notes version that
    /// grows when the notes change, a summary version that grows when the summary changes, and no
    /// summary provenance without a summary. Throws `StoreError.conflict` when `stored` is not the
    /// revision this copy was read at, and `StoreError.notFound` when a copy read from the store
    /// (revision above zero) meets no stored session: it was deleted, and is not created again.
    public func committed(over stored: Recording?) throws -> Recording {
        if let stored, stored.revision != revision { throw StoreError.conflict }
        if stored == nil, revision > 0 { throw StoreError.notFound }
        var updated = self; updated.revision += 1
        if updated.summary == nil { updated.summaryProvenance = nil }
        let notesChanged = stored?.notes != updated.notes || stored?.noteEntries != updated.noteEntries
        updated.notesVersion = max(1, (stored?.notesVersion ?? 0) + (notesChanged ? 1 : 0))
        updated.summaryVersion = updated.summary == nil ? nil : (stored?.summaryVersion ?? 0) + (stored?.summary != updated.summary ? 1 : 0)
        return updated
    }
}

/// Keeps sessions in memory with the same rules as `SessionStore`: revision check, versions,
/// sequence and outbox. Tests share one instance between a library and a simulated second writer.
public actor InMemoryRecordingRepository: RecordingRepository {
    private var stored: [UUID: Recording] = [:]
    private var history: [UUID: [Recording]] = [:]
    private var counter = 0
    private var outbox: [ExportOutboxEntry] = []

    public init(_ recordings: [Recording] = []) {
        for recording in recordings { stored[recording.id] = recording }
    }

    public func all() -> [Recording] {
        stored.values.sorted { $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt }
    }
    public func recording(_ id: UUID) throws -> Recording {
        guard let item = stored[id] else { throw IntegrationError("NOT_FOUND") }
        return item
    }
    public func revisions() -> [UUID: Int] { stored.mapValues(\.revision) }
    @discardableResult public func save(_ recording: Recording) throws -> Recording {
        let updated = try recording.committed(over: stored[recording.id])
        stored[updated.id] = updated
        history[updated.id, default: []].append(updated)
        counter += 1
        if updated.state != .recording { outbox.append(.publish(updated)) }
        return updated
    }
    /// Leaves `files` nil: this adapter keeps no files.
    @discardableResult public func remove(_ id: UUID) throws -> RecordingRemoval {
        if stored[id]?.state == .recording { throw StoreError.capturing }
        let removed = stored.removeValue(forKey: id)
        outbox.removeAll { if case .publish(let item) = $0 { item.id == id } else { false } }
        if let removed { outbox.append(.withdraw(id: id, revision: removed.revision + 1)) }
        counter += 1
        return RecordingRemoval(removed: removed)
    }
    public func removeOrphanFiles(now: Date) -> SessionFiles.Report? { nil }
    public func recoverInterrupted() throws -> Int {
        let interrupted = stored.values.filter { $0.state == .recording }
        for var item in interrupted { item.state = .interrupted; try save(item) }
        return interrupted.count
    }
    public func sequence() -> Int { counter }
    public func pendingExports() -> [ExportOutboxEntry] {
        outbox.filter { if case .withdraw = $0 { true } else { false } } + outbox.filter { if case .publish = $0 { true } else { false } }
    }
    public func acknowledgeExport(_ entry: ExportOutboxEntry) { outbox.removeAll { $0 == entry } }
    /// Every committed revision of a session, oldest first.
    public func versions(for id: UUID) -> [Recording] { history[id] ?? [] }
}
