import Foundation

/// Files a session owns in the data directory, outside SQLite.
///
/// - `audio/<id lowercased>/`: CAF chunks of both tracks, partial chunks, sequence descriptors, manifest, recovery notes.
/// - `cache/summaries/<ID>/`: summary checkpoints (extracted evidence, drafts).
/// - `cache/waveforms/<chunk id>-<bins>.json`: waveform envelopes, keyed by the first chunk of the session.
/// - `jobs/<uuid>/`: a transcription job (`request.json` names the session; result, log, echo and diarization scratch audio).
/// - `jobs/voice-<uuid>/`: a voice job (`request.json` embeds the session).
/// - `jobs/voice-audio-<uuid>/`: echo-cancelled scratch audio of a voice job, removed by the helper when it exits normally.
///
/// Voice fingerprints are not session files: they live in the keychain, per person, and are managed by the voice commands.
/// Every path is checked to stay inside the data directory, and a symbolic link is removed as a link, never followed.
public struct SessionFiles: Sendable {
    public struct Failure: Sendable, Equatable {
        public var path: String
        public var reason: String
    }
    public struct Report: Sendable, Equatable {
        /// Paths relative to the data directory.
        public var removed: [String] = []
        public var failures: [Failure] = []
        public var isComplete: Bool { failures.isEmpty }
    }

    public let root: URL
    public init(root: URL) { self.root = root }

    /// Removes the files of session `id`. `chunks` are its audio chunks. Files still referenced by a session of `live` are kept.
    public func remove(id: UUID, chunks: [AudioChunk], keeping live: [Recording]) -> Report {
        var report = Report()
        let livePaths = Set(live.flatMap(\.audioChunks).map(\.relativePath))
        let liveChunkIDs = Set(live.flatMap(\.audioChunks).map(\.id))
        for chunk in chunks where chunk.relativePath.hasPrefix("audio/") && !livePaths.contains(chunk.relativePath) {
            remove(chunk.relativePath, into: &report)
        }
        let audio = "audio/" + id.uuidString.lowercased()
        if !livePaths.contains(where: { $0.hasPrefix(audio + "/") }) { remove(audio, into: &report) }
        remove("cache/summaries/" + id.uuidString, into: &report)
        let ownChunks = Set(chunks.map(\.id)).subtracting(liveChunkIDs)
        for name in entries("cache/waveforms") where waveformChunk(name).map(ownChunks.contains) == true {
            remove("cache/waveforms/" + name, into: &report)
        }
        for name in entries("jobs") where jobOwner(name) == id { remove("jobs/" + name, into: &report) }
        return report
    }

    /// How long an entry must stay untouched before the sweep may treat it as an orphan.
    public static let orphanQuietPeriod: TimeInterval = 3600

    /// Removes files that belong to no session of `live`: audio and summary folders of unknown sessions, waveforms of unknown chunks,
    /// jobs whose request names an unknown session, and voice scratch audio. Anything it cannot attribute stays.
    /// An entry modified less than `quietPeriod` before `now`, itself or anything inside it, stays too: a capture that is
    /// starting writes its folder before its row reaches SQLite, so `live` cannot vouch for it. The sweep takes no capture lock.
    /// Call only while the helper cannot write, and never with an empty library: a missing or replaced database is not evidence
    /// that its sessions were deleted.
    public func removeOrphans(keeping live: [Recording], now: Date = .now, quietPeriod: TimeInterval = orphanQuietPeriod) -> Report {
        var report = Report()
        guard !live.isEmpty else { return report }
        let settled = { (relative: String) in isSettled(relative, before: now.addingTimeInterval(-quietPeriod)) }
        let liveIDs = Set(live.map(\.id))
        let livePaths = live.flatMap(\.audioChunks).map(\.relativePath)
        let liveChunkIDs = Set(live.flatMap(\.audioChunks).map(\.id))
        for name in entries("audio") {
            guard let id = UUID(uuidString: name), !liveIDs.contains(id), !livePaths.contains(where: { $0.hasPrefix("audio/\(name)/") }),
                  settled("audio/" + name) else { continue }
            remove("audio/" + name, into: &report)
        }
        for name in entries("cache/summaries") {
            guard let id = UUID(uuidString: name), !liveIDs.contains(id), settled("cache/summaries/" + name) else { continue }
            remove("cache/summaries/" + name, into: &report)
        }
        for name in entries("cache/waveforms") {
            guard let chunk = waveformChunk(name), !liveChunkIDs.contains(chunk), settled("cache/waveforms/" + name) else { continue }
            remove("cache/waveforms/" + name, into: &report)
        }
        for name in entries("jobs") {
            let scratch = name.hasPrefix("voice-audio-") && UUID(uuidString: String(name.dropFirst("voice-audio-".count))) != nil
            guard scratch || jobOwner(name).map({ !liveIDs.contains($0) }) == true, settled("jobs/" + name) else { continue }
            remove("jobs/" + name, into: &report)
        }
        return report
    }

    private var resolvedRoot: String { root.resolvingSymlinksInPath().standardizedFileURL.path }

    /// The entry named by `relative`, strictly inside the data directory. Only its parent is resolved.
    private func contained(_ relative: String) -> URL? {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let url = root.appendingPathComponent(relative)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let root = resolvedRoot
        guard parent == root || parent.hasPrefix(root + "/") else { return nil }
        return url
    }

    private func remove(_ relative: String, into report: inout Report) {
        guard let url = contained(relative) else {
            report.failures.append(.init(path: relative, reason: StoreError.invalidPath.localizedDescription)); return
        }
        // Does not follow a final symbolic link, unlike fileExists.
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return }
        do { try FileManager.default.removeItem(at: url); report.removed.append(relative) }
        catch { report.failures.append(.init(path: relative, reason: error.localizedDescription)) }
    }

    /// True when the entry and everything inside it were last modified before `limit`. Links are not followed.
    private func isSettled(_ relative: String, before limit: Date) -> Bool {
        guard let url = contained(relative) else { return false }
        func modified(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }
        guard let own = modified(url.path), own < limit else { return false }
        guard let names = FileManager.default.subpaths(atPath: url.path) else { return true }
        // subpaths does not descend into symbolic links.
        return names.allSatisfy { modified(url.appendingPathComponent($0).path).map { $0 < limit } ?? false }
    }

    private func entries(_ relative: String) -> [String] {
        guard let url = contained(relative) else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    private func waveformChunk(_ name: String) -> UUID? {
        guard name.hasSuffix(".json"), let dash = name.lastIndex(of: "-"),
              !name[name.index(after: dash)..<name.index(name.endIndex, offsetBy: -5)].isEmpty,
              name[name.index(after: dash)..<name.index(name.endIndex, offsetBy: -5)].allSatisfy(\.isNumber) else { return nil }
        return UUID(uuidString: String(name[..<dash]))
    }

    /// The session named by a job's request, nil when the folder is not a job or its request is unreadable.
    private func jobOwner(_ name: String) -> UUID? {
        struct Request: Decodable {
            struct Session: Decodable { var id: UUID }
            var recordingID: UUID?
            var recording: Session?
        }
        guard let folder = contained("jobs/" + name), (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let data = try? Data(contentsOf: folder.appendingPathComponent("request.json")),
              let request = try? JSONDecoder().decode(Request.self, from: data) else { return nil }
        return request.recordingID ?? request.recording?.id
    }
}
