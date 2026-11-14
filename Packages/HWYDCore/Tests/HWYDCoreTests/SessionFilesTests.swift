import XCTest
@testable import HWYDCore

/// Synthetic files only: placeholder bytes stand in for audio.
final class SessionFilesTests: XCTestCase, @unchecked Sendable {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HWYD-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.appendingPathComponent("audio").path)
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
    private func write(_ relative: String, in root: URL, _ text: String = "synthetic") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    /// Backdates an entry and everything inside it, as if nothing had written it for two hours.
    private func age(_ relative: String, in root: URL) throws {
        let url = root.appendingPathComponent(relative), old = Date.now.addingTimeInterval(-7200)
        for name in FileManager.default.subpaths(atPath: url.path) ?? [] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.appendingPathComponent(name).path)
        }
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
    }
    private func exists(_ relative: String, in root: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(relative).path)) != nil
    }
    /// A sealed session with two chunk pairs and every derived file the app writes for it.
    private func session(in root: URL, store: SessionStore, title: String) async throws -> Recording {
        var item = Recording(title: title, state: .sealed)
        let folder = "audio/" + item.id.uuidString.lowercased()
        for sequence in ["000000", "000001"] {
            for source in [AudioSource.mic, .system] {
                let path = "\(folder)/\(source.rawValue)-\(sequence).caf"
                try write(path, in: root)
                item.audioChunks.append(AudioChunk(source: source, relativePath: path, start: sequence == "000000" ? 0 : 300, duration: 300))
            }
            try write("\(folder)/\(sequence).json", in: root)
        }
        try write("\(folder)/manifest.json", in: root)
        try write("cache/summaries/\(item.id.uuidString)/evidence.json", in: root)
        try write("cache/waveforms/\(item.audioChunks[0].id.uuidString)-800.json", in: root)
        let job = try JSONEncoder().encode(TranscriptionRequest(recordingID: item.id, chunks: item.audioChunks))
        try write("jobs/\(UUID().uuidString)/request.json", in: root, String(decoding: job, as: UTF8.self))
        let voice = try JSONEncoder().encode(VoiceJob(recording: item))
        try write("jobs/voice-\(UUID().uuidString)/request.json", in: root, String(decoding: voice, as: UTF8.self))
        return try await store.save(item)
    }
    private func files(of item: Recording, in root: URL) throws -> [String] {
        var result = ["audio/" + item.id.uuidString.lowercased(), "cache/summaries/" + item.id.uuidString,
                      "cache/waveforms/\(item.audioChunks[0].id.uuidString)-800.json"]
        for name in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("jobs").path).sorted() {
            let data = try Data(contentsOf: root.appendingPathComponent("jobs/\(name)/request.json"))
            if let request = try? JSONDecoder().decode(TranscriptionRequest.self, from: data), request.recordingID == item.id { result.append("jobs/" + name) }
            if let job = try? JSONDecoder().decode(VoiceJob.self, from: data), job.recording.id == item.id { result.append("jobs/" + name) }
        }
        return result
    }

    func testDeletingASessionRemovesItsFilesAndKeepsOthers() async throws {
        let root = try directory(), store = try SessionStore(directory: root)
        let deleted = try await session(in: root, store: store, title: "À supprimer")
        let kept = try await session(in: root, store: store, title: "À garder")
        let deletedFiles = try files(of: deleted, in: root), keptFiles = try files(of: kept, in: root)
        XCTAssertEqual(deletedFiles.count, 5)
        let removal = try await store.remove(deleted.id); let report = try XCTUnwrap(removal.files)
        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(Set(deletedFiles).subtracting(report.removed), [])
        for path in deletedFiles { XCTAssertFalse(exists(path, in: root), path) }
        for path in keptFiles { XCTAssertTrue(exists(path, in: root), path) }
        let remaining = try await store.all()
        XCTAssertEqual(remaining.map(\.id), [kept.id])
        let versions = try await store.versions(for: deleted.id)
        XCTAssertTrue(versions.isEmpty)
    }

    func testRefusesToDeleteASessionThatIsCapturing() async throws {
        let root = try directory(), store = try SessionStore(directory: root)
        var item = Recording(title: "En cours", state: .recording)
        let path = "audio/\(item.id.uuidString.lowercased())/mic-000000.partial.caf"
        try write(path, in: root)
        item = try await store.save(item)
        do { _ = try await store.remove(item.id); XCTFail("Capturing session deleted") }
        catch { XCTAssertEqual(error as? StoreError, .capturing) }
        XCTAssertTrue(exists(path, in: root))
        let remaining = try await store.all()
        XCTAssertEqual(remaining.count, 1)
    }

    func testKeepsAChunkThatAnotherSessionStillReferences() async throws {
        let root = try directory(), store = try SessionStore(directory: root)
        let original = try await session(in: root, store: store, title: "Original")
        var copy = Recording(title: "Copie", state: .sealed); copy.audioChunks = original.audioChunks
        _ = try await store.save(copy)
        _ = try await store.remove(original.id)
        for chunk in original.audioChunks { XCTAssertTrue(exists(chunk.relativePath, in: root), chunk.relativePath) }
        XCTAssertTrue(exists("cache/waveforms/\(original.audioChunks[0].id.uuidString)-800.json", in: root))
        XCTAssertFalse(exists("cache/summaries/" + original.id.uuidString, in: root))
    }

    func testNeverFollowsALinkOutOfTheDataDirectory() async throws {
        let root = try directory(), outside = try directory()
        try write("precious.caf", in: outside)
        let store = try SessionStore(directory: root)
        var item = Recording(title: "Lien", state: .sealed)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("audio"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("audio/" + item.id.uuidString.lowercased()), withDestinationURL: outside)
        item.audioChunks = [AudioChunk(source: .mic, relativePath: "audio/\(item.id.uuidString.lowercased())/precious.caf", start: 0, duration: 1),
                            AudioChunk(source: .mic, relativePath: "audio/../../escape.caf", start: 0, duration: 1)]
        item = try await store.save(item)
        let removal = try await store.remove(item.id); let report = try XCTUnwrap(removal.files)
        XCTAssertTrue(exists("precious.caf", in: outside))
        XCTAssertFalse(exists("audio/" + item.id.uuidString.lowercased(), in: root), "The link itself is removed")
        XCTAssertEqual(report.failures.map(\.path).sorted(), ["audio/../../escape.caf", "audio/\(item.id.uuidString.lowercased())/precious.caf"])
    }

    func testReportsFilesThatCannotBeRemovedAndCleansThemOnNextLaunch() async throws {
        let root = try directory(), store = try SessionStore(directory: root)
        let item = try await session(in: root, store: store, title: "Verrouillée")
        _ = try await session(in: root, store: store, title: "Autre")
        let audio = root.appendingPathComponent("audio").path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: audio)
        let removal = try await store.remove(item.id); let report = try XCTUnwrap(removal.files)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: audio)
        XCTAssertFalse(report.isComplete)
        XCTAssertTrue(report.failures.contains { $0.path == "audio/" + item.id.uuidString.lowercased() })
        let remaining = try await store.all()
        XCTAssertFalse(remaining.contains { $0.id == item.id }, "No session row survives without its files")
        let sweep = try await store.removeOrphanFiles(now: .now.addingTimeInterval(7200))
        XCTAssertEqual(sweep?.isComplete, true)
        XCTAssertFalse(exists("audio/" + item.id.uuidString.lowercased(), in: root))
    }

    func testLaunchSweepRemovesOnlyFilesOfUnknownSessions() async throws {
        let root = try directory(), store = try SessionStore(directory: root)
        let live = try await session(in: root, store: store, title: "Vivante")
        let liveFiles = try files(of: live, in: root)
        let gone = UUID(), goneChunk = UUID()
        let orphans = ["audio/\(gone.uuidString.lowercased())/mic-000000.caf", "cache/summaries/\(gone.uuidString)/evidence.json",
                       "cache/waveforms/\(goneChunk.uuidString)-800.json", "jobs/voice-audio-\(UUID().uuidString)/mic.caf"]
        for path in orphans { try write(path, in: root) }
        let goneJob = String(decoding: try JSONEncoder().encode(TranscriptionRequest(recordingID: gone, chunks: [])), as: UTF8.self)
        try write("jobs/\(UUID().uuidString)/request.json", in: root, goneJob)
        let unattributed = ["audio/notes-perso/readme.txt", "cache/summaries/brouillon/x.json", "jobs/install-model.log",
                            "jobs/\(UUID().uuidString)/pipeline.log", "cache/waveforms/empty-800.json", "models/diarization/model.bin"]
        for path in unattributed { try write(path, in: root) }
        let report = try await store.removeOrphanFiles(now: .now.addingTimeInterval(7200))
        XCTAssertEqual(report?.isComplete, true)
        XCTAssertEqual(report?.removed.count, 5)
        for path in orphans { XCTAssertFalse(exists(path, in: root), path) }
        for path in liveFiles + unattributed { XCTAssertTrue(exists(path, in: root), path) }
    }

    func testLaunchSweepWaitsForHelperAndForALibrary() async throws {
        let root = try directory(), store = try SessionStore(directory: root)
        let orphan = "audio/\(UUID().uuidString.lowercased())"
        try write(orphan + "/mic-000000.caf", in: root); try age(orphan, in: root)
        let empty = try await store.removeOrphanFiles()
        XCTAssertEqual(empty, SessionFiles.Report(), "An empty library is no evidence of deletion")
        XCTAssertTrue(exists(orphan, in: root))
        _ = try await store.save(Recording(title: "Vivante", state: .sealed))
        let lock = open(root.appendingPathComponent("pipeline.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        let skipped = try await store.removeOrphanFiles()
        XCTAssertNil(skipped)
        XCTAssertTrue(exists(orphan, in: root))
        flock(lock, LOCK_UN); close(lock)
        let swept = try await store.removeOrphanFiles()
        XCTAssertEqual(swept?.removed, [orphan])
    }

    /// m10: a capture holds `capture.lock` for its whole duration. The sweep must neither need it nor take it.
    func testLaunchSweepRunsWhileACaptureHoldsItsLockAndLeavesTheLockFree() async throws {
        let root = try directory(), store = try SessionStore(directory: root)
        _ = try await store.save(Recording(title: "Vivante", state: .sealed))
        let orphan = "audio/\(UUID().uuidString.lowercased())"
        try write(orphan + "/mic-000000.caf", in: root); try age(orphan, in: root)
        let capture = open(root.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertEqual(flock(capture, LOCK_EX | LOCK_NB), 0)
        let swept = try await store.removeOrphanFiles()
        XCTAssertEqual(swept?.removed, [orphan])
        flock(capture, LOCK_UN); close(capture)
        let probe = open(root.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        defer { close(probe) }
        XCTAssertEqual(flock(probe, LOCK_EX | LOCK_NB), 0, "The sweep left capture.lock free for the next capture")
    }

    /// A starting capture writes `audio/<id>/` before its row reaches SQLite: a recent folder is never an orphan.
    func testLaunchSweepKeepsTheFolderOfACaptureNotYetInTheDatabase() async throws {
        let root = try directory(), store = try SessionStore(directory: root)
        _ = try await store.save(Recording(title: "Vivante", state: .sealed))
        let starting = "audio/\(UUID().uuidString.lowercased())"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(starting), withIntermediateDirectories: true)
        let resumed = "audio/\(UUID().uuidString.lowercased())"
        try write(resumed + "/mic-000000.caf", in: root); try age(resumed, in: root)
        try write(resumed + "/mic-000001.partial.caf", in: root)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-7200)], ofItemAtPath: root.appendingPathComponent(resumed).path)
        let orphan = "audio/\(UUID().uuidString.lowercased())"
        try write(orphan + "/mic-000000.caf", in: root); try age(orphan, in: root)
        let swept = try await store.removeOrphanFiles()
        XCTAssertEqual(swept?.removed, [orphan])
        XCTAssertTrue(exists(starting, in: root), "Empty folder just created by a starting capture")
        XCTAssertTrue(exists(resumed + "/mic-000000.caf", in: root), "Old folder with a chunk still being written")
        let later = try await store.removeOrphanFiles(now: .now.addingTimeInterval(SessionFiles.orphanQuietPeriod + 60))
        XCTAssertEqual(Set(later?.removed ?? []), [starting, resumed], "Once quiet and still unknown, they are orphans")
    }
}
