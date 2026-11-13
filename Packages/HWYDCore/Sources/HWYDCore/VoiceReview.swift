import Foundation

/// A stretch of one voice on its own track, in recording time.
public struct VoiceSpan: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

/// Per-voice review data for one recording. Derived from segments, never persisted.
public struct VoiceOverview: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case unidentified, proposed, confirmed, ignored }
    public var speaker: Speaker
    public var segmentCount: Int
    public var speechDuration: Double
    public var spans: [VoiceSpan]
    public var id: UUID { speaker.id }
    public var state: State {
        if speaker.ignored { return .ignored }
        if speaker.confirmed { return .confirmed }
        return speaker.proposedIdentity == nil ? .unidentified : .proposed
    }
}

/// Back-to-back playback of one voice. `at` is the offset in the playlist, `from`/`to` in the recording.
public struct VoicePlaylist: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var from: Double
        public var to: Double
        public var at: Double
    }
    public private(set) var entries: [Entry] = []
    public private(set) var length: Double = 0
    /// Overlapping spans are merged. A short silence separates distinct passages.
    public init(spans: [VoiceSpan], gap: Double = 0.35) {
        var merged: [VoiceSpan] = []
        for span in spans.filter({ $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }).sorted(by: { $0.start < $1.start }) {
            let span = VoiceSpan(start: max(0, span.start), end: span.end)
            if let last = merged.indices.last, span.start <= merged[last].end { merged[last].end = max(merged[last].end, span.end) }
            else { merged.append(span) }
        }
        var cursor = 0.0
        for (index, span) in merged.enumerated() {
            if index > 0 { cursor += gap }
            entries.append(Entry(from: span.start, to: span.end, at: cursor))
            cursor += span.end - span.start
        }
        length = cursor
    }
    /// Recording time heard after `elapsed` seconds of playlist. Gaps report the next passage.
    public func recordingTime(atElapsed elapsed: Double) -> Double {
        for entry in entries {
            if elapsed < entry.at { return entry.from }
            if elapsed < entry.at + (entry.to - entry.from) { return entry.from + (elapsed - entry.at) }
        }
        return entries.last?.to ?? 0
    }
}

public enum VoiceReviewError: LocalizedError, Equatable {
    case unnamedMerge, opposedPerson, sameVoice
    public var errorDescription: String? {
        switch self {
        case .unnamedMerge: String(localized: "Ces voix sont sur deux pistes différentes. Nommez d’abord l’une des deux.", bundle: .hwyd)
        case .opposedPerson: String(localized: "Cette personne est exclue de la reconnaissance.", bundle: .hwyd)
        case .sameVoice: String(localized: "Choisissez une autre voix.", bundle: .hwyd)
        }
    }
}

extension Recording {
    /// One entry per detected voice, in speaker order.
    public var voiceOverview: [VoiceOverview] {
        var bySpeaker: [UUID: [TranscriptSegment]] = [:]
        for segment in segments { if let id = segment.speakerID { bySpeaker[id, default: []].append(segment) } }
        return speakers.map { speaker in
            let owned = bySpeaker[speaker.id] ?? []
            return VoiceOverview(speaker: speaker, segmentCount: owned.count,
                                 speechDuration: owned.reduce(0) { $0 + max(0, $1.end - $1.start) },
                                 spans: owned.map { VoiceSpan(start: $0.start, end: $0.end) })
        }
    }

    /// The user states that two detected voices are one person.
    /// Same track: segments move to the target and the duplicate cluster disappears. Each segment
    /// remembers its first detected voice, so `separateSpeaker` can undo the merge later.
    /// Different tracks: clusters stay separate (channel categories differ) and share the name.
    /// This is a transcript correction only. It never creates or changes a voice print.
    public mutating func mergeSpeaker(_ sourceID: UUID, into targetID: UUID) throws {
        guard sourceID != targetID else { throw VoiceReviewError.sameVoice }
        guard let s = speakers.firstIndex(where: { $0.id == sourceID }),
              let t = speakers.firstIndex(where: { $0.id == targetID }) else { throw StoreError.notFound }
        let source = speakers[s], target = speakers[t]
        if source.source == target.source {
            for index in segments.indices where segments[index].speakerID == sourceID {
                if segments[index].originalSpeakerID == nil { segments[index].originalSpeakerID = sourceID }
                segments[index].speakerID = targetID
            }
            if !target.confirmed && source.confirmed { adoptIdentity(of: source, at: t) }
            absorbedSpeakers = (absorbedSpeakers ?? []).filter { $0.id != sourceID } + [source]
            speakers.remove(at: s)
        } else {
            guard let identity = target.confirmed ? target : source.confirmed ? source : nil else { throw VoiceReviewError.unnamedMerge }
            adoptIdentity(of: identity, at: s)
            adoptIdentity(of: identity, at: t)
        }
        transcriptVersion += 1
        summary = nil
    }

    /// Voices once merged into this one whose passages it still holds.
    public func separableVoices(of speakerID: UUID) -> [Speaker] {
        let held = Set(segments.lazy.filter { $0.speakerID == speakerID }.compactMap(\.originalSpeakerID))
        return (absorbedSpeakers ?? []).filter { held.contains($0.id) }
    }

    /// Undoes a merge: the passages first detected as `absorbedID` and still held by `speakerID`
    /// return to that voice, which reappears as it was when merged.
    public mutating func separateSpeaker(_ absorbedID: UUID, from speakerID: UUID) throws {
        guard let a = absorbedSpeakers?.firstIndex(where: { $0.id == absorbedID }),
              speakers.contains(where: { $0.id == speakerID }) else { throw StoreError.notFound }
        let moved = segments.indices.filter { segments[$0].speakerID == speakerID && segments[$0].originalSpeakerID == absorbedID }
        guard !moved.isEmpty else { throw StoreError.notFound }
        for index in moved { segments[index].speakerID = absorbedID; segments[index].originalSpeakerID = nil }
        let voice = absorbedSpeakers!.remove(at: a)
        if absorbedSpeakers?.isEmpty == true { absorbedSpeakers = nil }
        // The voice kept the identity it had lent when merged: the other one gives it back.
        if voice.confirmed, let t = speakers.firstIndex(where: { $0.id == speakerID }), speakers[t].confirmed,
           speakers[t].label == voice.label, speakers[t].personID == voice.personID {
            speakers[t].confirmed = false; speakers[t].personID = nil; speakers[t].proposedIdentity = nil
            speakers[t].label = "Voix à nommer" // l10n:ignore (stored label, see docs/localization.md)
        }
        speakers.append(voice)
        transcriptVersion += 1
        summary = nil
    }

    /// Shows the person voice memory proposes for each voice nobody confirmed or ignored. The
    /// proposal stays to be confirmed; the transcript version does not change. Returns how many
    /// voices received one. Matches naming an unknown person are dropped.
    @discardableResult
    public mutating func proposeIdentities(_ matches: VoiceMatches, people: [VoicePerson]) -> Int {
        var proposed = 0
        for index in speakers.indices where !speakers[index].confirmed && !speakers[index].ignored {
            guard let match = matches[speakers[index].id], let person = people.first(where: { $0.id == match.personID }) else { continue }
            speakers[index].proposedIdentity = match; speakers[index].label = person.name
            proposed += 1
        }
        return proposed
    }

    /// Confirms a voice as a known person: the one mutation behind the voice tiles, an enrollment
    /// and an MCP rename. The name is validated and an opposed person refused. Linking is not
    /// enrollment: no vector is read or written.
    public mutating func linkSpeaker(_ id: UUID, to person: VoicePerson) throws {
        guard !person.opposed else { throw VoiceReviewError.opposedPerson }
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound }
        let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { throw StoreError.invalidName }
        speakers[index].label = name; speakers[index].personID = person.id
        speakers[index].confirmed = true; speakers[index].proposedIdentity = nil
        transcriptVersion += 1
        summary = nil
    }

    private mutating func adoptIdentity(of identity: Speaker, at index: Int) {
        speakers[index].label = identity.label; speakers[index].personID = identity.personID
        speakers[index].confirmed = true; speakers[index].proposedIdentity = nil
    }

    /// Hides a voice that is not a participant (echo of the speakers, noise), or restores it.
    /// Segments are kept, so the change is reversible. Identity and voice prints are untouched.
    public mutating func setSpeakerIgnored(_ id: UUID, _ ignored: Bool) throws {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound }
        guard speakers[index].ignored != ignored else { return }
        speakers[index].ignored = ignored
        transcriptVersion += 1
        summary = nil
    }

    /// Segments heard at `time`, on any track.
    public func segmentIDs(at time: Double) -> Set<UUID> {
        Set(segments.lazy.filter { $0.start <= time && time < $0.end }.map(\.id))
    }
}
