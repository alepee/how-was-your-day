import Foundation

/// Where committed sessions are published for other tools. The repository keeps what is left to
/// publish (its outbox); `ExportOutbox.drain` hands it over after each commit seen.
///
/// Adapters: `FolderExportPublisher` (Markdown and JSON generations in a folder, `SessionExporter`)
/// and `InMemoryExportPublisher` (tests).
public protocol ExportPublisher: Sendable {
    /// Publishes this revision of the session.
    func publish(_ recording: Recording) async throws
    /// Withdraws a deleted session; `revision` is the deletion's own revision.
    func withdraw(_ id: UUID, revision: Int) async throws
}

/// Publishes into a folder: the configured publication folder, or the one the user picks for a
/// one-off export.
public actor FolderExportPublisher: ExportPublisher {
    public nonisolated let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func publish(_ recording: Recording) throws { try SessionExporter.export(recording, to: directory) }
    public func withdraw(_ id: UUID, revision: Int) throws {
        try SessionExporter.delete(id: id.uuidString.lowercased(), revision: revision, from: directory)
    }
}

/// Records what it was given, for tests.
public actor InMemoryExportPublisher: ExportPublisher {
    public private(set) var published: [Recording] = []
    public private(set) var withdrawn: [UUID] = []
    public init() {}
    public func publish(_ recording: Recording) { published.append(recording) }
    public func withdraw(_ id: UUID, revision: Int) { withdrawn.append(id) }
}

public enum ExportOutbox {
    /// Hands every pending entry to `publisher`, in order, and removes each one once published.
    /// A failing entry does not hold back other sessions: only the later entries of its own
    /// session wait, so they stay in order. Throws the first failure once every other entry was
    /// tried; the entries left are published at the next drain.
    public static func drain(_ repository: any RecordingRepository, to publisher: any ExportPublisher) async throws {
        var failure: Error?, blocked = Set<UUID>()
        for entry in try await repository.pendingExports() {
            let id: UUID = switch entry { case .publish(let recording): recording.id; case .withdraw(let id, _): id }
            guard !blocked.contains(id) else { continue }
            do {
                switch entry {
                case .publish(let recording): try await publisher.publish(recording)
                case .withdraw(let id, let revision): try await publisher.withdraw(id, revision: revision)
                }
                try await repository.acknowledgeExport(entry)
            } catch {
                blocked.insert(id)
                if failure == nil { failure = error }
            }
        }
        if let failure { throw failure }
    }
}
