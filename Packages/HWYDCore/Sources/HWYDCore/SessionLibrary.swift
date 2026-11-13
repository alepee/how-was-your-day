import Foundation
import Observation

/// What happened to the library, for the presentation to report.
public enum LibraryChange: Equatable, Sendable {
    /// Every pending edit reached the repository.
    case saved
    /// Pending edits could not be saved and stay pending. The reason is localized.
    case saveFailed(String)
    /// Sessions another process added, changed or removed, merged into the library.
    case external(Set<UUID>)
    /// Pending edits of a session were rebased on another writer's commit. `conflicts` lists the
    /// parts both sides changed, where the local side was kept; the other side stays in the history.
    case rebased(UUID, conflicts: Set<RecordingPart>)
    /// Publication failed; what is left is published at the next commit seen. The reason is localized.
    case exportDeferred(String)
    /// Another writer deleted a session that held pending edits: the edits were dropped with it.
    case removedElsewhere(UUID, title: String)
}

/// The session changed since the work read it: its result is not applied.
public struct StaleResult: Error, Equatable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

/// The result was applied to the working copy but could not be saved. It stays a pending edit,
/// saved by the next save; the library already reported `.saveFailed`.
public struct UnsavedResult: LocalizedError, Sendable {
    public let id: UUID
    public let reason: String
    public init(id: UUID, reason: String) { self.id = id; self.reason = reason }
    public var errorDescription: String? { reason }
}

/// The sessions shown by the app and the rules for changing them: local edits are applied at
/// once, saved after a short pause, rebased on other writers' commits instead of being lost, and
/// published after each commit. Work that ran on a copy (transcription, voices, summary) applies
/// its result through `apply(_:ifStillAt:where:_:)`, which refuses a result the session outgrew.
///
/// A library over a repository saves and watches it; a volatile library (previews, demo) keeps
/// its sessions in memory and saves nothing. Repository work (save, read, publish) runs one
/// operation at a time; edits never wait.
@MainActor @Observable
public final class SessionLibrary {
    /// Working copies, newest first: what the user sees, pending edits included.
    public private(set) var recordings: [Recording] = []
    /// Some edit has not reached the repository yet, or its save failed.
    public private(set) var hasUnsavedChanges = false
    public private(set) var savedAt: Date?
    /// The first load finished, or the library is volatile.
    public private(set) var isReady: Bool

    @ObservationIgnored private let repository: (any RecordingRepository)?
    @ObservationIgnored private let exportTarget: @Sendable () async throws -> (any ExportPublisher)?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let watchInterval: Duration?
    /// The stored version each working copy was last rebased on.
    @ObservationIgnored private var base: [UUID: Recording] = [:]
    @ObservationIgnored private var dirty: Set<UUID> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var lastSequence: Int?
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var observers: [UUID: AsyncStream<LibraryChange>.Continuation] = [:]
    @ObservationIgnored private var operating = false
    @ObservationIgnored private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    /// `exportTarget` gives the publisher of the moment, nil when publication is off; it is asked
    /// at each drain, so a folder chosen later applies at once. `watchInterval` nil turns off the
    /// watch of other writers (tests call `checkForChanges()` themselves).
    public init(repository: any RecordingRepository,
                exportTarget: @escaping @Sendable () async throws -> (any ExportPublisher)? = { nil },
                debounce: Duration = .milliseconds(300), watchInterval: Duration? = .seconds(2)) {
        self.repository = repository; self.exportTarget = exportTarget
        self.debounce = debounce; self.watchInterval = watchInterval
        isReady = false
    }

    /// Sessions kept in memory only: edits apply, nothing is saved, published or watched.
    public init(volatile recordings: [Recording]) {
        repository = nil; exportTarget = { nil }; debounce = .zero; watchInterval = nil
        self.recordings = recordings; isReady = true
    }

    public func recording(_ id: UUID) -> Recording? { recordings.first { $0.id == id } }

    /// Returns once the first load is done, failed or not.
    public var ready: Void {
        get async {
            if isReady { return }
            await withCheckedContinuation { readyWaiters.append($0) }
        }
    }

    /// Every change from now on, for one observer.
    public var changes: AsyncStream<LibraryChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: LibraryChange.self, bufferingPolicy: .bufferingNewest(32))
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.observers[id] = nil } }
        return stream
    }

    // MARK: Loading and watching

    /// Starts watching other writers, recovers captures a crash left open, reads every session
    /// (rebasing pending edits) and publishes what is pending. Returns how many captures were
    /// recovered. The library is ready once this returns, even after a failure; after a failure
    /// the watch reads every session again at its next tick.
    @discardableResult
    public func load() async throws -> Int {
        defer { becomeReady() }
        guard let repository else { return 0 }
        startWatching()
        await acquire(); defer { release() }
        let recovered = try await repository.recoverInterrupted()
        try await reloadLocked(repository, at: repository.sequence())
        await publishLocked()
        return recovered
    }

    /// Merges what other processes committed since the last check, and publishes it. One read of
    /// the sequence when nothing changed; only changed sessions are decoded. Pending local edits
    /// are rebased; they are dropped only with a session another writer deleted. Before a first
    /// successful read, every session is read.
    public func checkForChanges() async {
        guard let repository else { return }
        await acquire(); defer { release() }
        do {
            let sequence = try await repository.sequence()
            guard sequence != lastSequence else { return }
            guard lastSequence != nil else {
                let ids = try await reloadLocked(repository, at: sequence)
                if !ids.isEmpty { emit(.external(ids)) }
                await publishLocked()
                return
            }
            let revisions = try await repository.revisions()
            var changed: [Recording] = []
            for (id, revision) in revisions where base[id]?.revision != revision {
                if let item = try? await repository.recording(id) { changed.append(item) }
            }
            let ids = integrate(changed, removed: base.keys.filter { revisions[$0] == nil })
            lastSequence = sequence
            if !ids.isEmpty { emit(.external(ids)) }
            await publishLocked()
        } catch {
            // A busy or unreadable store is checked again at the next tick.
        }
    }

    /// Reads every session, read at `sequence`.
    @discardableResult
    private func reloadLocked(_ repository: any RecordingRepository, at sequence: Int) async throws -> Set<UUID> {
        let stored = try await repository.all()
        let present = Set(stored.map(\.id))
        let ids = integrate(stored, removed: base.keys.filter { !present.contains($0) })
        lastSequence = sequence
        return ids
    }

    private func startWatching() {
        guard watchTask == nil, let interval = watchInterval else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.checkForChanges()
            }
        }
    }

    // MARK: Editing

    /// Applies `mutation` to the working copy now and saves it after a short pause. Returns false
    /// when the session is unknown. A mutation that changes nothing saves nothing.
    @discardableResult
    public func edit(_ id: UUID, _ mutation: (inout Recording) throws -> Void) rethrows -> Bool {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return false }
        var item = recordings[index]
        try mutation(&item)
        guard item != recordings[index] else { return true }
        recordings[index] = item
        markDirty(id)
        return true
    }

    /// Adds a new session, or replaces the working copy of a known one, and saves it.
    public func insert(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        recordings.insert(recording, at: recordings.firstIndex { Self.isOrdered(recording, before: $0) } ?? recordings.endIndex)
        markDirty(recording.id)
    }

    /// Replaces what a volatile library shows, for previews and snapshots.
    public func show(_ recordings: [Recording]) {
        precondition(repository == nil, "Only a volatile library is replaced without saving")
        self.recordings = recordings
    }

    /// Saves every pending edit now. A save that meets another writer's commit is rebased on it
    /// and tried again; a failure is reported and the edits stay pending.
    public func flush() async {
        await acquire(); defer { release() }
        await drainLocked()
    }

    /// Applies the result of work that read the session at transcript version `version`, unless
    /// the session changed since, here or in another process: pending edits are saved and the
    /// stored session is merged first, then `isCurrent` decides with the transcript version.
    /// Throws `StaleResult` and changes nothing when the result is outdated, or the session is
    /// gone. Once this returns, the result is saved; when the save fails, it throws `UnsavedResult`
    /// and the result stays a pending edit. A failure to read the stored session is thrown as is.
    @discardableResult
    public func apply(_ id: UUID, ifStillAt version: Int, where isCurrent: (Recording) throws -> Bool = { _ in true },
                      _ mutation: (inout Recording) throws -> Void) async throws -> Recording {
        await acquire(); defer { release() }
        await drainLocked()
        if let repository, base[id] != nil {
            do { integrate([try await repository.recording(id)]) }
            catch where Self.isNotFound(error) { throw StaleResult(id: id) }
        }
        guard var item = recording(id), item.transcriptVersion == version, try isCurrent(item) else { throw StaleResult(id: id) }
        try mutation(&item)
        if let index = recordings.firstIndex(where: { $0.id == id }), recordings[index] != item {
            recordings[index] = item
            markDirty(id, scheduling: false)
            if let failure = await drainLocked() { throw UnsavedResult(id: id, reason: failure.localizedDescription) }
            guard recording(id) != nil else { throw StaleResult(id: id) }
        }
        return recording(id) ?? item
    }

    /// Deletes the session from the repository, then from the library, and publishes its withdrawal.
    @discardableResult
    public func remove(_ id: UUID) async throws -> RecordingRemoval {
        await acquire(); defer { release() }
        let removal = try await repository?.remove(id) ?? RecordingRemoval(removed: recording(id))
        recordings.removeAll { $0.id == id }
        base[id] = nil; dirty.remove(id)
        if dirty.isEmpty { hasUnsavedChanges = false }
        await publishLocked()
        return removal
    }

    /// Publishes what the outbox holds, for instance once a publication folder is chosen.
    public func publishExports() async {
        await acquire(); defer { release() }
        await publishLocked()
    }

    // MARK: Internals

    private func markDirty(_ id: UUID, scheduling: Bool = true) {
        guard repository != nil else { return }
        dirty.insert(id); hasUnsavedChanges = true
        if scheduling { scheduleSave() }
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard let self else { return }
            self.saveTask = nil
            await self.flush()
        }
    }

    /// Saves dirty sessions one by one. Edits made while a save is in flight stay in the working
    /// copy and are saved by the next turn of the loop. A session another writer deleted is not
    /// saved again: it leaves the library with its pending edits. Returns the failure, if any,
    /// after reporting it.
    @discardableResult
    private func drainLocked() async -> Error? {
        guard let repository else { return nil }
        var conflicts: [UUID: Int] = [:], saved = false
        while let id = dirty.first {
            dirty.remove(id)
            guard let sent = recording(id) else { continue }
            do {
                committed(try await repository.save(sent), sent: sent); saved = true
            } catch StoreError.notFound {
                // Saved before, and deleted since by another writer.
                discard(id)
            } catch let error as StoreError where error == .conflict && conflicts[id, default: 0] < 3 {
                conflicts[id, default: 0] += 1
                dirty.insert(id)
                do { integrate([try await repository.recording(id)]) }
                catch where Self.isNotFound(error) { dirty.remove(id); discard(id) }
                catch { fail(error); return error }
            } catch {
                dirty.insert(id); fail(error); return error
            }
        }
        hasUnsavedChanges = false
        guard saved else { return nil }
        savedAt = Date()
        emit(.saved)
        await publishLocked()
        return nil
    }

    /// Takes what the repository stored. Later edits to the working copy are kept.
    private func committed(_ saved: Recording, sent: Recording) {
        base[saved.id] = saved
        guard let index = recordings.firstIndex(where: { $0.id == saved.id }) else { return }
        if recordings[index] == sent { recordings[index] = saved; return }
        recordings[index].revision = saved.revision
        recordings[index].notesVersion = saved.notesVersion; recordings[index].summaryVersion = saved.summaryVersion
    }

    /// Takes stored versions into the working copies: a clean copy is replaced, a dirty one is
    /// rebased. Sessions removed elsewhere leave the library; pending edits leave with them, and
    /// the user is told.
    @discardableResult
    private func integrate(_ stored: [Recording], removed: [UUID] = []) -> Set<UUID> {
        var changed = Set<UUID>()
        for remote in stored {
            let known = base[remote.id], index = recordings.firstIndex { $0.id == remote.id }
            // Nothing new since the copy was last rebased.
            if index != nil, known?.revision == remote.revision { continue }
            changed.insert(remote.id)
            base[remote.id] = remote
            if let index {
                if dirty.contains(remote.id) {
                    let (merged, conflicts) = Recording.merge(base: known, local: recordings[index], remote: remote)
                    recordings[index] = merged
                    emit(.rebased(remote.id, conflicts: conflicts))
                } else { recordings[index] = remote }
            } else {
                recordings.insert(remote, at: recordings.firstIndex { Self.isOrdered(remote, before: $0) } ?? recordings.endIndex)
            }
        }
        for id in removed {
            if dirty.contains(id) { discard(id); continue }
            base[id] = nil
            if recordings.contains(where: { $0.id == id }) { recordings.removeAll { $0.id == id }; changed.insert(id) }
        }
        return changed
    }

    /// Drops a session another writer deleted while it held pending edits, and says so.
    private func discard(_ id: UUID) {
        let title = recording(id)?.title ?? ""
        base[id] = nil; dirty.remove(id)
        recordings.removeAll { $0.id == id }
        if dirty.isEmpty { hasUnsavedChanges = false }
        emit(.removedElsewhere(id, title: title))
    }

    private static func isNotFound(_ error: Error) -> Bool {
        (error as? IntegrationError)?.code == "NOT_FOUND" || (error as? StoreError) == .notFound
    }

    private func fail(_ error: Error) {
        hasUnsavedChanges = true
        emit(.saveFailed(error.localizedDescription))
    }

    private func publishLocked() async {
        guard let repository else { return }
        do {
            guard let publisher = try await exportTarget() else { return }
            try await ExportOutbox.drain(repository, to: publisher)
        } catch { emit(.exportDeferred(error.localizedDescription)) }
    }

    private func emit(_ change: LibraryChange) {
        for observer in observers.values { observer.yield(change) }
    }

    private func becomeReady() {
        isReady = true
        let waiters = readyWaiters; readyWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private static func isOrdered(_ item: Recording, before other: Recording) -> Bool {
        item.startedAt == other.startedAt ? item.id.uuidString < other.id.uuidString : item.startedAt > other.startedAt
    }

    /// Repository work runs one operation at a time, in the order asked.
    private func acquire() async {
        guard operating else { operating = true; return }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func release() {
        if operationWaiters.isEmpty { operating = false } else { operationWaiters.removeFirst().resume() }
    }
}
