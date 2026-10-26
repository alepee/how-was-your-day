import Foundation
import CryptoKit
import Darwin

public enum SessionExporter {
    static func uuid(_ seed: String) -> String {
        let h = SHA256.hash(data: Data(seed.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(h.prefix(8))-\(h.dropFirst(8).prefix(4))-\(h.dropFirst(12).prefix(4))-\(h.dropFirst(16).prefix(4))-\(h.dropFirst(20))"
    }
    static func micros(_ seconds: Double) -> Int64 { Int64((max(0, min(seconds.isFinite ? seconds : 0, 1e10)) * 1e6).rounded()) }
    static func nullable<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
    public static func artifact(_ item: Recording, _ name: String) -> String {
        switch name {
        case "notes": return item.noteEntries.sorted { $0.offset < $1.offset }.map { "- [\(timeLabel($0.offset, hours: true))] \($0.text)" }.joined(separator: "\n") + "\n\n" + item.notes
        case "summary": return item.summary ?? "Synthèse non activée ou invalidée après correction."
        default:
            return item.segments.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }.map { segment in
                let label = item.speakers.first { $0.id == segment.speakerID }?.label ?? "Voix inconnue"
                return "**[\(timeLabel(segment.start, hours: true)) - \(timeLabel(segment.end, hours: true))] \(escape(label)) (\(segment.source == .mic ? "micro" : "système"))** : \(segment.text)"
            }.joined(separator: "\n\n")
        }
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
    public static func document(_ item: Recording, exportedAt: Date = Date()) throws -> [String: Any] {
        let id = item.id.uuidString.lowercased()
        func track(_ source: AudioSource) -> String { uuid(id + source.rawValue) }
        let channel: (AudioSource) -> String = { $0 == .system ? "remote" : "room" }
        let summaryProvenance = item.summary == nil ? nil : item.summaryProvenance
        let summary: [String: Any] = ["status": item.summary == nil ? "disabled" : "ready", "provider": nullable(summaryProvenance?.provider), "model": nullable(summaryProvenance?.model), "model_revision": NSNull(), "prompt_version": nullable(summaryProvenance?.promptVersion), "prompt_hash": nullable(summaryProvenance?.promptHash), "generated_at": nullable(summaryProvenance?.generatedAt.ISO8601Format()), "transcript_version": nullable(summaryProvenance?.transcriptVersion), "notes_version": NSNull(), "markdown": nullable(item.summary), "structured": try summaryProvenance.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0.structured)) } ?? NSNull(), "schema_version": 1, "options": ["draft": true], "error_code": NSNull()]
        var calendar: Any = NSNull()
        if let event = item.calendarContext {
            calendar = ["provider": "eventkit", "event_id": event.id, "calendar_id": NSNull(), "title": event.title, "description": nullable(event.details), "location": nullable(event.location), "url": nullable(event.meetingURL?.absoluteString), "starts_at": event.start.ISO8601Format(), "ends_at": event.end.ISO8601Format(), "participants": event.participants.map { ["name": nullable($0.name), "email": nullable($0.email), "response": "unknown"] }, "links": event.meetingURL.map { [$0.absoluteString] } ?? [], "attachments": [], "attachments_status": "unavailable"] as [String: Any]
        }
        return ["hwyd_schema": 1, "is_demo": item.isDemo, "type": "Session", "id": id, "source": "hwyd://session/" + id,
            "revision": item.revision, "transcript_version": item.transcriptVersion, "notes_version": item.notesVersion ?? item.revision, "summary_version": nullable(item.summary == nil ? nil : item.summaryVersion),
            "date": String(item.startedAt.ISO8601Format().prefix(10)), "started_at": item.startedAt.ISO8601Format(), "ended_at": item.startedAt.addingTimeInterval(item.duration).ISO8601Format(), "timezone": "UTC", "duration_us": micros(item.duration), "title": item.title, "session_kind": item.kind.rawValue, "app": item.calendarContext?.meetingURL?.host == "meet.google.com" ? "meet" : "unknown", "status": item.state == .recording ? "capturing" : item.transcriptState == .ready ? "complete" : "partial", "locale": nullable(item.transcription?.locale), "consent_announced": item.consentAnnounced,
            "participants": item.participants.map { ["id": ($0.personID ?? $0.id).uuidString.lowercased(), "name": $0.label, "alias": NSNull()] as [String: Any] }, "calendar": calendar,
            "audio": ["state": item.audioChunks.isEmpty ? "missing" : "available", "retention_hours": NSNull(), "expires_at": NSNull(), "encryption": "volume_only"], "summary": summary,
            "tracks": [AudioSource.mic, .system].filter { source in item.audioChunks.contains { $0.source == source } || item.segments.contains { $0.source == source } }.map { ["id": track($0), "source": $0.rawValue, "channel": channel($0), "sample_rate": 16000, "channels": 1] as [String: Any] },
            "speakers": item.speakers.map { speaker in ["id": speaker.id.uuidString, "label": speaker.label, "track_id": track(speaker.source), "channel": channel(speaker.source), "identity": ["status": speaker.confirmed ? "confirmed" : speaker.proposedIdentity == nil ? "anonymous" : "proposed", "person_id": nullable(speaker.confirmed ? speaker.personID?.uuidString : nil), "persistent_speaker_id": NSNull(), "name": nullable(speaker.confirmed ? speaker.label : nil), "alias": NSNull(), "proposed_person_id": nullable(speaker.proposedIdentity?.personID.uuidString), "scores": nullable(speaker.proposedIdentity.map { ["acoustic": $0.score, "adjusted": $0.score, "margin": nullable($0.margin), "threshold": 0.75, "calendar_bonus": 0, "cross_channel": false, "policy_version": "experimental-v1"] as [String: Any] })]] as [String: Any] },
            "segments": item.segments.map { segment in ["id": segment.id.uuidString, "start_us": micros(segment.start), "end_us": micros(segment.end), "track_id": track(segment.source), "speaker_id": nullable(segment.speakerID?.uuidString), "text": segment.text, "confidence": NSNull(), "flags": segment.words == nil ? ["timing_coarse"] : [], "words": (segment.words ?? []).enumerated().map { index, word in ["id": uuid(segment.id.uuidString + String(index)), "text": word.text, "start_us": micros(word.start), "end_us": micros(word.end), "confidence": NSNull(), "timing_quality": "word"] as [String: Any] }] as [String: Any] },
            "gaps": [], "notes": ["version": item.notesVersion ?? item.revision, "markdown": item.notes, "entries": item.noteEntries.map { ["id": $0.id.uuidString, "offset_us": micros($0.offset), "text": $0.text] as [String: Any] }],
            "provenance": ["pipeline_version": "hwyd-0.2", "run_id": NSNull(), "asr": [], "diarizer": [], "echo_policy": "not-applied", "alignment_policy": "word-overlap", "identity_policy": "experimental-v1"], "exported_at": exportedAt.ISO8601Format()]
    }
    public static func export(_ recording: Recording, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(directory.appendingPathComponent("export.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw StoreError.invalidPath }; defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw StoreError.conflict }; defer { flock(lock, LOCK_UN) }
        let id = recording.id.uuidString.lowercased(), revision = recording.revision
        if let data = try? Data(contentsOf: directory.appendingPathComponent("index.jsonl")) {
            for line in data.split(separator: 10) {
                if let entry = try? parseEntry(Data(line)), entry["id"] as? String == id, entry["op"] as? String == "delete" { throw StoreError.conflict }
            }
        }
        let relative = ".hwyd/generations/\(id)/\(revision)"
        let generation = directory.appendingPathComponent(relative)
        let jsonURL = generation.appendingPathComponent("session.json")
        var exportedAt = Date()
        if let old = try? Data(contentsOf: jsonURL), let object = try? JSONSerialization.jsonObject(with: old) as? [String: Any], let date = object["exported_at"] as? String { exportedAt = ISO8601DateFormatter().date(from: date) ?? exportedAt }
        let object = try document(recording, exportedAt: exportedAt)
        let json = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let front = object.filter { !["tracks", "speakers", "segments", "gaps", "notes", "provenance"].contains($0.key) }
        // JSON is a YAML subset; one serializer escapes every user-supplied frontmatter value.
        let yaml = String(decoding: try JSONSerialization.data(withJSONObject: front, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let markdown = Data(("---\n" + yaml + "\n---\n\n# " + escape(recording.title) + "\n\n## Notes\n\n" + artifact(recording, "notes") + "\n\n## Summary\n\n" + artifact(recording, "summary") + "\n\n## Transcript\n\n" + artifact(recording, "transcript") + "\n").utf8)
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let manifest = try JSONSerialization.data(withJSONObject: ["id": id, "revision": revision, "files": ["session.md": ["sha256": hash(markdown), "bytes": markdown.count], "session.json": ["sha256": hash(json), "bytes": json.count]]], options: [.sortedKeys])
        if FileManager.default.fileExists(atPath: generation.path) {
            guard try Data(contentsOf: jsonURL) == json, try Data(contentsOf: generation.appendingPathComponent("session.md")) == markdown else { throw StoreError.conflict }
        } else {
            let parent = generation.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let temporary = parent.appendingPathComponent(".tmp-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            for (name, data) in [("session.md", markdown), ("session.json", json), ("manifest.json", manifest)] { try durableWrite(data, to: temporary.appendingPathComponent(name)) }
            try FileManager.default.moveItem(at: temporary, to: generation)
        }
        let index = directory.appendingPathComponent("index.jsonl")
        var indexData = (try? Data(contentsOf: index)) ?? Data()
        if !indexData.isEmpty, indexData.last != 10 { indexData = indexData.lastIndex(of: 10).map { indexData.prefix(through: $0) } ?? Data() }
        let entries = try indexData.split(separator: 10).map { try parseEntry(Data($0)) }
        let latest = entries.filter { $0["id"] as? String == id }.compactMap { $0["revision"] as? Int }.max() ?? -1
        if !entries.contains(where: { $0["id"] as? String == id && $0["revision"] as? Int == revision }) {
            let entry: [String: Any] = ["hwyd_schema": 1, "event_id": uuid(id + "-" + String(revision)), "seq": (entries.compactMap { $0["seq"] as? Int }.max() ?? 0) + 1, "op": "upsert", "id": id, "revision": revision, "date": object["date"]!, "kind": recording.kind.rawValue, "title": recording.title, "path": relative + "/session.md", "json_path": relative + "/session.json", "manifest_path": relative + "/manifest.json", "published_at": exportedAt.ISO8601Format()]
            indexData.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])); indexData.append(10)
            // Atomic journal replacement preserves the append-only event sequence and repairs only a partial tail.
            try durableWrite(indexData, to: index)
        }
        guard revision >= latest else { return }
        let base = "session-\(String(recording.startedAt.ISO8601Format().prefix(10)))-\(id)"
        for (suffix, data) in [("md", markdown), ("json", json)] {
            let file = directory.appendingPathComponent(base + "." + suffix)
            let hashFile = directory.appendingPathComponent(".hwyd/" + base + "." + suffix + ".sha256")
            if let previous = try? Data(contentsOf: file), let lastHash = try? String(contentsOf: hashFile, encoding: .utf8), hash(previous) != lastHash {
                try durableWrite(previous, to: directory.appendingPathComponent(base + ".conflict-" + UUID().uuidString + "." + suffix))
            }
            try durableWrite(data, to: file); try durableWrite(Data(hash(data).utf8), to: hashFile)
        }
    }
    public static func delete(id: String, revision: Int, from directory: URL) throws {
        guard UUID(uuidString: id) != nil else { throw StoreError.invalidPath }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(directory.appendingPathComponent("export.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw StoreError.invalidPath }; defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw StoreError.conflict }; defer { flock(lock, LOCK_UN) }
        let index = directory.appendingPathComponent("index.jsonl")
        var data = (try? Data(contentsOf: index)) ?? Data()
        if !data.isEmpty, data.last != 10 { data = data.lastIndex(of: 10).map { data.prefix(through: $0) } ?? Data() }
        let entries = try data.split(separator: 10).map { try parseEntry(Data($0)) }
        if !entries.contains(where: { $0["id"] as? String == id && $0["op"] as? String == "delete" }) {
            let event: [String: Any] = ["hwyd_schema": 1, "event_id": uuid(id + "-delete"), "seq": (entries.compactMap { $0["seq"] as? Int }.max() ?? 0) + 1, "op": "delete", "id": id, "revision": revision, "date": NSNull(), "kind": NSNull(), "title": NSNull(), "path": NSNull(), "json_path": NSNull(), "manifest_path": NSNull(), "published_at": Date().ISO8601Format()]
            data.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])); data.append(10)
            try durableWrite(data, to: index)
        }
        let generations = directory.appendingPathComponent(".hwyd/generations/" + id)
        if FileManager.default.fileExists(atPath: generations.path) { try FileManager.default.removeItem(at: generations) }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("session-") && file.lastPathComponent.contains(id) { try FileManager.default.removeItem(at: file) }
    }
    static func parseEntry(_ data: Data) throws -> [String: Any] {
        guard let entry = try JSONSerialization.jsonObject(with: data) as? [String: Any], entry["seq"] is Int, entry["revision"] is Int, entry["id"] is String else { throw StoreError.conflict }
        return entry
    }
    static func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let file = try FileHandle(forWritingTo: url); try file.synchronize(); try file.close()
        let dir = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        if dir >= 0 { _ = fsync(dir); close(dir) }
    }
}
