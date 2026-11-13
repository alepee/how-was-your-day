import XCTest
@testable import HWYDCore

/// A repository whose next save waits until the test lets it through, to edit while it is in flight.
private actor GatedRepository: RecordingRepository {
    let inner = InMemoryRecordingRepository()
    private var holding = false, arrived = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?

    func holdNextSave() { holding = true; arrived = false }
    func waitForHeldSave() async { if !arrived { await withCheckedContinuation { arrival = $0 } } }
    func releaseSave() { gate?.resume(); gate = nil }

    func save(_ recording: Recording) async throws -> Recording {
        if holding {
            holding = false; arrived = true
            arrival?.resume(); arrival = nil
            await withCheckedContinuation { gate = $0 }
        }
        return try await inner.save(recording)
    }
    func all() async throws -> [Recording] { await inner.all() }
    func recording(_ id: UUID) async throws -> Recording { try await inner.recording(id) }
    func revisions() async throws -> [UUID: Int] { await inner.revisions() }
    func remove(_ id: UUID) async throws -> RecordingRemoval { try await inner.remove(id) }
    func removeOrphanFiles(now: Date) async throws -> SessionFiles.Report? { await inner.removeOrphanFiles(now: now) }
    func recoverInterrupted() async throws -> Int { try await inner.recoverInterrupted() }
    func sequence() async throws -> Int { await inner.sequence() }
    func pendingExports() async throws -> [ExportOutboxEntry] { await inner.pendingExports() }
    func acknowledgeExport(_ entry: ExportOutboxEntry) async throws { await inner.acknowledgeExport(entry) }
}

/// A repository whose reads or saves fail while the test says so.
private actor FaultyRepository: RecordingRepository {
    struct Failure: LocalizedError { var errorDescription: String? { "disque indisponible" } }
    let inner = InMemoryRecordingRepository()
    private var failingLoad = false, failingSave = false, failingRead = false
    func failLoad(_ on: Bool) { failingLoad = on }
    func failSave(_ on: Bool) { failingSave = on }
    func failRead(_ on: Bool) { failingRead = on }
    private var failingSweep = false
    func failSweep(_ on: Bool) { failingSweep = on }

    func all() async throws -> [Recording] {
        if failingLoad { throw Failure() }
        return await inner.all()
    }
    func recording(_ id: UUID) async throws -> Recording {
        if failingRead { throw Failure() }
        return try await inner.recording(id)
    }
    func save(_ recording: Recording) async throws -> Recording {
        if failingSave { throw Failure() }
        return try await inner.save(recording)
    }
    func revisions() async throws -> [UUID: Int] { await inner.revisions() }
    func remove(_ id: UUID) async throws -> RecordingRemoval { try await inner.remove(id) }
    func removeOrphanFiles(now: Date) async throws -> SessionFiles.Report? {
        if failingSweep { throw Failure() }
        return await inner.removeOrphanFiles(now: now)
    }
    func recoverInterrupted() async throws -> Int { try await inner.recoverInterrupted() }
    func sequence() async throws -> Int { await inner.sequence() }
    func pendingExports() async throws -> [ExportOutboxEntry] { await inner.pendingExports() }
    func acknowledgeExport(_ entry: ExportOutboxEntry) async throws { await inner.acknowledgeExport(entry) }
}

/// A publisher that refuses one session, as a folder whose index withdrew it.
private actor RefusingPublisher: ExportPublisher {
    struct Refused: Error {}
    let refused: UUID
    private(set) var published: [UUID] = []
    init(refusing id: UUID) { refused = id }
    func publish(_ recording: Recording) throws {
        guard recording.id != refused else { throw Refused() }
        published.append(recording.id)
    }
    func withdraw(_ id: UUID, revision: Int) throws {}
}

@MainActor
final class SessionLibraryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HWYD-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A library that saves only when asked and never watches by itself.
    private func library(_ repository: any RecordingRepository, publisher: (any ExportPublisher)? = nil) async throws -> SessionLibrary {
        let library = SessionLibrary(repository: repository, exportTarget: { publisher }, debounce: .seconds(3600), watchInterval: nil)
        try await library.load()
        return library
    }

    private func stored(_ title: String, in library: SessionLibrary) async -> Recording {
        let item = Recording(title: title)
        library.insert(item)
        await library.flush()
        return library.recording(item.id)!
    }

    // MARK: Lost edits

    func testEditMadeWhileASaveIsInFlightIsSavedToo() async throws {
        let repository = GatedRepository()
        let library = try await library(repository)
        let item = await stored("Point d’équipe", in: library)

        await repository.holdNextSave()
        library.edit(item.id) { $0.notes = "Première ligne" }
        let flushing = Task { await library.flush() }
        await repository.waitForHeldSave()
        library.edit(item.id) { $0.notes = "Première ligne\nDeuxième ligne" }
        await repository.releaseSave()
        await flushing.value

        let saved = try await repository.recording(item.id)
        XCTAssertEqual(saved.notes, "Première ligne\nDeuxième ligne")
        XCTAssertEqual(library.recording(item.id), saved)
        XCTAssertFalse(library.hasUnsavedChanges)
    }

    func testAnotherWritersCommitIsMergedWithoutLosingPendingEdits() async throws {
        let repository = InMemoryRecordingRepository()
        let library = try await library(repository)
        let changes = library.changes
        let item = await stored("Avant", in: library)

        library.edit(item.id) { $0.title = "Titre de l’app" }
        var external = try await repository.recording(item.id); external.notes = "Note de l’agent"
        try await repository.save(external)
        await library.checkForChanges()

        let merged = try XCTUnwrap(library.recording(item.id))
        XCTAssertEqual(merged.title, "Titre de l’app")
        XCTAssertEqual(merged.notes, "Note de l’agent")
        XCTAssertTrue(library.hasUnsavedChanges)
        await library.flush()
        let saved = try await repository.recording(item.id)
        XCTAssertEqual(saved.title, "Titre de l’app")
        XCTAssertEqual(saved.notes, "Note de l’agent")
        var iterator = changes.makeAsyncIterator()
        var seen: [LibraryChange] = []
        while let change = await iterator.next() { seen.append(change); if change == .saved, seen.count > 2 { break } }
        XCTAssertTrue(seen.contains(.rebased(item.id, conflicts: [])), "\(seen)")
        XCTAssertTrue(seen.contains(.external([item.id])), "\(seen)")
    }

    func testCleanCopyFollowsAnotherWriterAndADeletionElsewhere() async throws {
        let repository = InMemoryRecordingRepository()
        let library = try await library(repository)
        let kept = await stored("Gardée", in: library), deleted = await stored("Supprimée ailleurs", in: library)
        var external = try await repository.recording(kept.id); external.notes = "Nouvelle note"
        try await repository.save(external)
        try await repository.remove(deleted.id)
        await library.checkForChanges()
        XCTAssertEqual(library.recording(kept.id)?.notes, "Nouvelle note")
        XCTAssertNil(library.recording(deleted.id))
        XCTAssertFalse(library.hasUnsavedChanges)
    }

    func testPendingEditOfASessionDeletedElsewhereIsDroppedNotRecreated() async throws {
        let repository = InMemoryRecordingRepository()
        let library = try await library(repository)
        let changes = library.changes
        let item = await stored("Supprimée ailleurs", in: library)

        library.edit(item.id) { $0.notes = "Note en attente" }
        try await repository.remove(item.id)
        await library.checkForChanges()
        XCTAssertNil(library.recording(item.id))
        XCTAssertFalse(library.hasUnsavedChanges)
        await library.flush()
        let left = await repository.all()
        XCTAssertTrue(left.isEmpty)
        var iterator = changes.makeAsyncIterator()
        var removed: LibraryChange?
        while let change = await iterator.next() { if case .removedElsewhere = change { removed = change; break } }
        XCTAssertEqual(removed, .removedElsewhere(item.id, title: "Supprimée ailleurs"))
    }

    func testSaveOfASessionDeletedSinceItWasReadDoesNotRecreateIt() async throws {
        let store = try SessionStore(directory: directory())
        let library = try await library(store)
        let item = await stored("Supprimée par l’agent", in: library)

        library.edit(item.id) { $0.notes = "Note en attente" }
        try await store.remove(item.id)
        await library.flush()
        let left = try await store.all()
        XCTAssertTrue(left.isEmpty)
        XCTAssertNil(library.recording(item.id))
        XCTAssertFalse(library.hasUnsavedChanges)
    }

    func testAFailedFirstLoadIsReadAgainByTheWatch() async throws {
        let repository = FaultyRepository()
        try await repository.inner.save(Recording(title: "Hier"))
        await repository.failLoad(true)
        let library = SessionLibrary(repository: repository, debounce: .seconds(3600), watchInterval: .milliseconds(10))
        do { try await library.load(); XCTFail("The load did not fail") } catch {}
        XCTAssertTrue(library.isReady)
        XCTAssertTrue(library.recordings.isEmpty)

        await repository.failLoad(false)
        for _ in 0..<1000 where library.recordings.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(library.recordings.map(\.title), ["Hier"])
    }

    // MARK: Revision conflicts with an MCP write

    func testMCPWriteBetweenEditAndSaveIsRebasedNotOverwritten() async throws {
        let store = try SessionStore(directory: directory())
        try await store.setMCPWritesEnabled(true)
        let library = try await library(store)
        let item = await stored("Revue", in: library)

        library.edit(item.id) { $0.title = "Revue produit" }
        _ = try await store.mutate(id: item.id, expectedRevision: item.revision, requestID: UUID(), notes: "Ajouté par l’agent")
        await library.flush()

        let saved = try await store.recording(item.id)
        XCTAssertEqual(saved.title, "Revue produit")
        XCTAssertEqual(saved.notes, "Ajouté par l’agent")
        XCTAssertEqual(saved.revision, item.revision + 2)
        XCTAssertEqual(library.recording(item.id), saved)
        XCTAssertFalse(library.hasUnsavedChanges)
    }

    func testSamePartChangedByBothKeepsTheAppsEditAndTheHistoryKeepsTheOther() async throws {
        let store = try SessionStore(directory: directory())
        try await store.setMCPWritesEnabled(true)
        let library = try await library(store)
        let changes = library.changes
        let item = await stored("Revue", in: library)

        library.edit(item.id) { $0.notes = "Note de l’app" }
        _ = try await store.mutate(id: item.id, expectedRevision: item.revision, requestID: UUID(), notes: "Note de l’agent")
        await library.flush()

        let saved = try await store.recording(item.id)
        XCTAssertEqual(saved.notes, "Note de l’app")
        let history = try await store.versions(for: item.id).map(\.notes)
        XCTAssertTrue(history.contains("Note de l’agent"))
        var iterator = changes.makeAsyncIterator()
        var rebased: LibraryChange?
        while let change = await iterator.next() { if case .rebased = change { rebased = change; break } }
        XCTAssertEqual(rebased, .rebased(item.id, conflicts: [.notes]))
    }

    // MARK: Stale results

    func testResultOfWorkIsRejectedOnceTheTranscriptChangedHere() async throws {
        let repository = InMemoryRecordingRepository()
        let library = try await library(repository)
        let voice = Speaker(label: "Voix 1")
        let item = Recording(title: "Atelier", speakers: [voice], segments: [.init(start: 0, end: 2, speakerID: voice.id, source: .mic, text: "Bonjour")])
        library.insert(item); await library.flush()
        let read = try XCTUnwrap(library.recording(item.id))

        try library.edit(item.id) { try $0.assignSpeaker(nil, to: item.segments[0].id) }
        do {
            try await library.apply(item.id, ifStillAt: read.transcriptVersion) { $0.summary = "Synthèse périmée" }
            XCTFail("Stale result applied")
        } catch { XCTAssertEqual(error as? StaleResult, StaleResult(id: item.id)) }
        XCTAssertNil(library.recording(item.id)?.summary)
        let saved = try await repository.recording(item.id)
        XCTAssertNil(saved.summary)
        XCTAssertEqual(saved.segments[0].speakerID, nil)
    }

    func testResultOfWorkIsRejectedOnceAnotherProcessChangedTheTranscript() async throws {
        let store = try SessionStore(directory: directory())
        try await store.setMCPWritesEnabled(true)
        let library = try await library(store)
        let voice = Speaker(label: "Voix 1"), camille = VoicePerson(name: "Camille")
        try await store.savePerson(camille)
        let item = Recording(title: "Atelier", speakers: [voice], segments: [.init(start: 0, end: 2, speakerID: voice.id, source: .mic, text: "Bonjour")])
        library.insert(item); await library.flush()
        let read = try XCTUnwrap(library.recording(item.id))

        // Renamed through MCP; the library has not looked yet.
        _ = try await store.mutate(id: item.id, expectedRevision: read.revision, requestID: UUID(), speaker: voice.id, personID: camille.id)
        do {
            try await library.apply(item.id, ifStillAt: read.transcriptVersion) { $0.summary = "Synthèse périmée" }
            XCTFail("Stale result applied")
        } catch { XCTAssertEqual(error as? StaleResult, StaleResult(id: item.id)) }
        let current = try XCTUnwrap(library.recording(item.id))
        XCTAssertEqual(current.speakers.first?.label, "Camille")
        XCTAssertNil(current.summary)

        let applied = try await library.apply(item.id, ifStillAt: current.transcriptVersion) { $0.summary = "Synthèse à jour" }
        let saved = try await store.recording(item.id)
        XCTAssertEqual(saved.summary, "Synthèse à jour")
        XCTAssertEqual(applied, saved)
    }

    func testApplyChecksTheCallersOwnCondition() async throws {
        let library = try await library(InMemoryRecordingRepository())
        let item = await stored("Atelier", in: library)
        do {
            try await library.apply(item.id, ifStillAt: item.transcriptVersion, where: { _ in false }) { $0.summary = "x" }
            XCTFail("Stale result applied")
        } catch { XCTAssertTrue(error is StaleResult) }
        XCTAssertNil(library.recording(item.id)?.summary)
    }

    func testResultThatCannotBeSavedThrowsAndStaysPending() async throws {
        let repository = FaultyRepository()
        let library = try await library(repository)
        let item = await stored("Atelier", in: library)
        await repository.failSave(true)
        do {
            try await library.apply(item.id, ifStillAt: item.transcriptVersion) { $0.summary = "Synthèse" }
            XCTFail("An unsaved result was reported as saved")
        } catch { XCTAssertEqual((error as? UnsavedResult)?.id, item.id) }
        XCTAssertEqual(library.recording(item.id)?.summary, "Synthèse")
        XCTAssertTrue(library.hasUnsavedChanges)

        await repository.failSave(false)
        await library.flush()
        let saved = try await repository.recording(item.id)
        XCTAssertEqual(saved.summary, "Synthèse")
    }

    func testApplySurfacesAReadFailureInsteadOfCallingTheResultStale() async throws {
        let repository = FaultyRepository()
        let library = try await library(repository)
        let item = await stored("Atelier", in: library)
        await repository.failRead(true)
        do {
            try await library.apply(item.id, ifStillAt: item.transcriptVersion) { $0.summary = "Synthèse" }
            XCTFail("Applied without reading the stored session")
        } catch {
            XCTAssertFalse(error is StaleResult)
            XCTAssertTrue(error is FaultyRepository.Failure)
        }
        XCTAssertNil(library.recording(item.id)?.summary)
    }

    func testApplyOnASessionDeletedElsewhereIsStale() async throws {
        let repository = InMemoryRecordingRepository()
        let library = try await library(repository)
        let item = await stored("Atelier", in: library)
        try await repository.remove(item.id)
        do {
            try await library.apply(item.id, ifStillAt: item.transcriptVersion) { $0.summary = "Synthèse" }
            XCTFail("Applied to a deleted session")
        } catch { XCTAssertEqual(error as? StaleResult, StaleResult(id: item.id)) }
        let left = await repository.all()
        XCTAssertTrue(left.isEmpty)
    }

    // MARK: Publication and readiness

    func testOneRefusedSessionDoesNotHoldBackTheOthers() async throws {
        let repository = InMemoryRecordingRepository()
        let refused = Recording(title: "Refusée", startedAt: Date(timeIntervalSince1970: 1)), other = Recording(title: "Publiée", startedAt: Date(timeIntervalSince1970: 2))
        try await repository.save(refused); try await repository.save(other)
        let publisher = RefusingPublisher(refusing: refused.id)
        do { try await ExportOutbox.drain(repository, to: publisher); XCTFail("The refusal was not reported") }
        catch { XCTAssertTrue(error is RefusingPublisher.Refused) }
        let published = await publisher.published
        XCTAssertEqual(published, [other.id])
        let left: [UUID?] = await repository.pendingExports().map { entry -> UUID? in if case .publish(let item) = entry { item.id } else { nil } }
        XCTAssertEqual(left, [refused.id])
    }

    func testCommitsAreHandedToThePublisherIncludingAnotherWritersAndDeletions() async throws {
        let repository = InMemoryRecordingRepository(), publisher = InMemoryExportPublisher()
        let library = try await library(repository, publisher: publisher)
        let item = await stored("Publiée", in: library)
        var published = await publisher.published
        XCTAssertEqual(published.map(\.revision), [item.revision])

        var external = try await repository.recording(item.id); external.notes = "Écrit par l’agent"
        try await repository.save(external)
        await library.checkForChanges()
        published = await publisher.published
        XCTAssertEqual(published.last?.notes, "Écrit par l’agent")

        try await library.remove(item.id)
        let withdrawn = await publisher.withdrawn
        XCTAssertEqual(withdrawn, [item.id])
        let left = await repository.pendingExports()
        XCTAssertTrue(left.isEmpty)
    }

    func testCapturingSessionIsSavedButNotPublished() async throws {
        let repository = InMemoryRecordingRepository(), publisher = InMemoryExportPublisher()
        let library = try await library(repository, publisher: publisher)
        library.insert(Recording(title: "En cours", state: .recording)); await library.flush()
        let published = await publisher.published
        XCTAssertTrue(published.isEmpty)
    }

    func testReadyWaitsForTheFirstLoad() async throws {
        let library = SessionLibrary(repository: InMemoryRecordingRepository([Recording(title: "Hier")]), debounce: .seconds(3600), watchInterval: nil)
        XCTAssertFalse(library.isReady)
        let waiter = Task { await library.ready; return library.recordings.count }
        try await library.load()
        let count = await waiter.value
        XCTAssertEqual(count, 1)
        XCTAssertTrue(SessionLibrary(volatile: []).isReady)
    }

    func testVolatileLibraryEditsWithoutSaving() {
        let item = Recording(title: "Exemple", isDemo: true)
        let library = SessionLibrary(volatile: [item])
        library.edit(item.id) { $0.notes = "Modifiable" }
        XCTAssertEqual(library.recording(item.id)?.notes, "Modifiable")
        XCTAssertFalse(library.hasUnsavedChanges)
    }

    // MARK: Merge rules

    func testSummaryFollowsTheTranscriptItWasMadeFrom() {
        let voice = Speaker(label: "Voix 1")
        let base = Recording(title: "Atelier", speakers: [voice], segments: [.init(start: 0, end: 2, speakerID: voice.id, source: .mic, text: "Bonjour")])
        var local = base; local.summary = "Synthèse locale"
        var remote = base
        try? remote.renameSpeaker(voice.id, to: "Camille")
        remote.revision = base.revision + 1
        let (merged, conflicts) = Recording.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.speakers.first?.label, "Camille")
        XCTAssertNil(merged.summary)
        XCTAssertEqual(merged.revision, remote.revision)
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testTranscriptChangedOnBothSidesGetsAVersionNeitherSideUsed() {
        let voice = Speaker(label: "Voix 1")
        let base = Recording(title: "Atelier", speakers: [voice], segments: [.init(start: 0, end: 2, speakerID: voice.id, source: .mic, text: "Bonjour")])
        var local = base; local.segments[0].text = "Bonjour à tous"; local.transcriptVersion += 1
        var remote = base; remote.segments[0].text = "Bonjour tout le monde"; remote.transcriptVersion += 1; remote.revision = base.revision + 1
        let (merged, conflicts) = Recording.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(conflicts, [.transcript])
        XCTAssertEqual(merged.segments[0].text, "Bonjour à tous")
        XCTAssertEqual(merged.transcriptVersion, remote.transcriptVersion + 1)
    }

    func testNeverStoredCopyKeepsEveryLocalPart() {
        let local = Recording(title: "Locale", notes: "Note locale")
        var remote = local; remote.title = "Distante"; remote.revision = 3
        let (merged, conflicts) = Recording.merge(base: nil, local: local, remote: remote)
        XCTAssertEqual(merged.title, "Locale")
        XCTAssertEqual(merged.revision, 3)
        XCTAssertEqual(conflicts, [.title])
    }

    // MARK: Session files

    func testRemovingASessionReturnsWhatHappenedToItsFiles() async throws {
        let root = try directory(), store = try SessionStore(directory: root)
        let library = try await library(store)
        var item = Recording(title: "Avec audio", state: .sealed)
        let audio = "audio/" + item.id.uuidString.lowercased()
        item.audioChunks = [AudioChunk(source: .mic, relativePath: audio + "/mic-000000.caf", start: 0, duration: 1)]
        try FileManager.default.createDirectory(at: root.appendingPathComponent(audio), withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: root.appendingPathComponent(audio + "/mic-000000.caf"))
        library.insert(item); await library.flush()

        let removal = try await library.remove(item.id)
        XCTAssertEqual(removal.files?.isComplete, true)
        XCTAssertTrue(removal.files?.removed.contains(audio) == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(audio).path))
    }

    func testCapturingSessionCannotBeRemoved() async throws {
        let repository = InMemoryRecordingRepository()
        let library = try await library(repository)
        let item = Recording(title: "En cours", state: .recording)
        library.insert(item); await library.flush()
        do { try await library.remove(item.id); XCTFail("A capturing session was removed") }
        catch { XCTAssertEqual(error as? StoreError, .capturing) }
        XCTAssertNotNil(library.recording(item.id))
        let removal = try await repository.remove(UUID())
        XCTAssertNil(removal.files, "The in-memory repository keeps no files")
    }

    func testLoadSweepsFilesOfSessionsDeletedEarlierOnceReady() async throws {
        let root = try directory(), store = try SessionStore(directory: root)
        try await store.save(Recording(title: "Gardée", state: .sealed))
        let earlier = root.appendingPathComponent("audio/\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: earlier.appendingPathComponent("mic-000000.caf"))
        let quiet = Date.now.addingTimeInterval(-2 * SessionFiles.orphanQuietPeriod)
        for url in [earlier.appendingPathComponent("mic-000000.caf"), earlier] {
            try FileManager.default.setAttributes([.modificationDate: quiet], ofItemAtPath: url.path)
        }
        let library = try await library(store)
        XCTAssertTrue(library.isReady)
        await library.fileSweep?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: earlier.path))
    }

    func testEmptyLibraryIsNotSwept() async throws {
        let root = try directory(), store = try SessionStore(directory: root)
        let unknown = root.appendingPathComponent("audio/\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        let library = try await library(store)
        XCTAssertNil(library.fileSweep)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
    }

    func testFailedSweepIsReported() async throws {
        let repository = FaultyRepository()
        try await repository.inner.save(Recording(title: "Hier"))
        await repository.failSweep(true)
        let library = SessionLibrary(repository: repository, debounce: .seconds(3600), watchInterval: nil)
        let changes = library.changes
        try await library.load()
        await library.fileSweep?.value
        var iterator = changes.makeAsyncIterator()
        let change = await iterator.next()
        XCTAssertEqual(change, .fileSweepFailed("disque indisponible"))
    }
}
