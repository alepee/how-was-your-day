import Foundation

/// One embedding the diarizer computed for a voice inside one of its analysis windows.
/// In memory only: deliberately not `Codable`, so it cannot reach a file, an export or the store.
public struct VoiceWindow: Sendable {
    public var speakerID: UUID
    /// First and last moment the voice is active inside the window.
    public var start: Double
    public var end: Double
    public var vector: [Float]
    public init(speakerID: UUID, start: Double, end: Double, vector: [Float]) {
        self.speakerID = speakerID; self.start = start; self.end = end; self.vector = vector
    }
    var span: VoiceCoherence.Span { .init(start: start, end: end) }
    var duration: Double { end - start }
}

/// A voice the post-processing found to hold two people. It names the passages of the smaller part;
/// nothing moves until the user accepts. It never carries a vector.
public struct VoiceSplitProposal: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var speakerID: UUID
    /// Passages of the smaller part, which would become a new voice.
    public var segmentIDs: [UUID]
    /// Cosine between the two parts: low means two different people.
    public var similarity: Double
    /// Known person the smaller part sounds like, when voice memory found one.
    public var proposedIdentity: VoiceMatch?
    /// Voice of the same track the smaller part sounds like, when there is one.
    public var mergeInto: UUID?
    public init(id: UUID = UUID(), speakerID: UUID, segmentIDs: [UUID], similarity: Double) {
        self.id = id; self.speakerID = speakerID; self.segmentIDs = segmentIDs; self.similarity = similarity
    }
}

/// What the post-processing measured for one voice. Durations, shares and cosines only.
public struct VoiceMeasure: Codable, Equatable, Sendable {
    public init(speechSeconds: Double = 0, embeddedSeconds: Double = 0) { self.speechSeconds = speechSeconds; self.embeddedSeconds = embeddedSeconds }
    public var speechSeconds = 0.0
    /// Share of the voice's speech during which the other track speaks.
    public var crossTrackOverlap = 0.0
    /// Seconds of speech covered by the diarizer's embeddings of this voice.
    public var embeddedSeconds = 0.0
    public var split: Split?
    /// Most similar longer voice of the same track.
    public var nearestLonger: UUID?
    public var nearestLongerCosine: Double?
    public struct Split: Codable, Equatable, Sendable {
        public var similarity: Double
        public var smallSeconds: Double
        public var smallLevelDB: Double?
        public var largeLevelDB: Double?
        public var smallFirstMinute: Double
        public var smallLastMinute: Double
        /// Speech of the passages that would move, once levels passed. Nil when the check stopped before.
        public var movedSeconds: Double?
        public var proposed = false
    }
}

/// Decides, after diarization, what each detected voice is: an echo of the call, two people in one
/// voice, the same person as another voice, or a voice too brief to name. Thresholds were measured on
/// real sessions and live here, not in settings. See docs/voice-post-processing.md.
public struct VoicePostProcessor {
    public static let engine = "hwyd-voice-post-processing-v1"
    /// A microphone voice is an echo when the other track speaks during at least this share of it.
    public static let echoOverlap = 0.70
    /// The coherence check only trusts windows where the voice speaks nearly alone for this long.
    public static let soloWindowSeconds = 9.0
    /// Two groups of one voice less similar than this are two people; so are two voices more similar one person.
    public static let samePersonSimilarity = 0.75
    public static let splitMinimumSeconds = 30.0
    /// Both groups must be at a normal speech level and close to each other: a distant voice or a
    /// very low microphone gain scores like two people.
    public static let splitMinimumLevelDB = -40.0
    public static let splitMaximumLevelGapDB = 10.0
    public static let identificationSeconds = 20.0
    public static let mergeMinimumSeconds = 2.0
    public static let minorSeconds = 30.0
    public static let minorShare = 0.01

    public private(set) var recording: Recording
    public private(set) var measures: [UUID: VoiceMeasure] = [:]
    private var windows: [UUID: [VoiceWindow]] = [:]
    /// Unit centroid of each voice: of its larger part while a split is proposed.
    private var centroids: [UUID: [Float]] = [:]
    /// Centroid and embedded seconds of the smaller part of each proposal.
    private var minority: [UUID: (centroid: [Float], seconds: Double)] = [:]

    public init(recording: Recording, windows: [VoiceWindow]) {
        self.recording = recording
        let known = Set(recording.speakers.map(\.id))
        for window in windows where known.contains(window.speakerID) && window.end > window.start && window.vector.allSatisfy(\.isFinite) {
            self.windows[window.speakerID, default: []].append(window)
        }
        var speech: [UUID: Double] = [:]
        for segment in recording.segments { if let id = segment.speakerID { speech[id, default: 0] += max(0, segment.end - segment.start) } }
        for speaker in recording.speakers {
            let own = self.windows[speaker.id] ?? []
            measures[speaker.id] = VoiceMeasure(speechSeconds: speech[speaker.id] ?? 0, embeddedSeconds: VoiceCoherence.seconds(own.map(\.span)))
            if !own.isEmpty { centroids[speaker.id] = VoiceCoherence.centroid(own.map(\.vector), weights: own.map(\.duration)) }
        }
    }

    /// Runs every step that needs no outside help. Identification, which reads voice memory, comes
    /// between `mergeDuplicates` and `classify`: see `identificationCandidates`.
    public mutating func detect(level: ([VoiceCoherence.Span], AudioSource) -> Double?) {
        markEchoes(); proposeSplits(level: level); mergeDuplicates()
    }

    /// Step 5. A microphone voice heard almost only while the call speaks is the call itself, picked
    /// up by the microphone: hidden like an ignored voice, and out of the following steps.
    public mutating func markEchoes() {
        for index in recording.speakers.indices where recording.speakers[index].source == .mic {
            let overlap = VoiceCoherence.crossTrackOverlap(of: recording.speakers[index].id, in: recording.segments).share
            measures[recording.speakers[index].id]?.crossTrackOverlap = overlap
            if overlap >= Self.echoOverlap { recording.speakers[index].ignored = true; recording.speakers[index].automatic = .echo }
        }
    }

    /// Step 6. Splits the embeddings of each voice in two groups. Two groups as different as two
    /// people, each long enough and at a normal level, become a proposal the user answers.
    public mutating func proposeSplits(level: ([VoiceCoherence.Span], AudioSource) -> Double?) {
        var proposals: [VoiceSplitProposal] = []
        for speaker in recording.speakers where !speaker.ignored {
            let own = windows[speaker.id] ?? []
            let solo = own.filter { $0.duration >= Self.soloWindowSeconds }
            guard let split = VoiceCoherence.split(solo.map(\.vector), weights: solo.map(\.duration)) else { continue }
            let groups = (0...1).map { group in solo.indices.filter { split.assignment[$0] == group }.map { solo[$0] } }
            let seconds = groups.map { VoiceCoherence.seconds($0.map(\.span)) }
            let small = seconds[0] <= seconds[1] ? 0 : 1
            let spans = VoiceCoherence.union(groups[small].map(\.span))
            var measure = VoiceMeasure.Split(similarity: split.between, smallSeconds: seconds[small],
                                             smallFirstMinute: (spans.first?.start ?? 0) / 60, smallLastMinute: (spans.last?.end ?? 0) / 60)
            defer { measures[speaker.id]?.split = measure }
            guard split.between < Self.samePersonSimilarity, seconds[small] >= Self.splitMinimumSeconds else { continue }
            measure.smallLevelDB = level(spans, speaker.source)
            measure.largeLevelDB = level(VoiceCoherence.union(groups[1 - small].map(\.span)), speaker.source)
            guard let quiet = measure.smallLevelDB, let loud = measure.largeLevelDB, min(quiet, loud) >= Self.splitMinimumLevelDB,
                  abs(quiet - loud) <= Self.splitMaximumLevelGapDB else { continue }
            // Every window of the voice joins the nearer group, then each passage the group that covers it most.
            let parts = [1 - small, small].map { group in VoiceCoherence.centroid(groups[group].map(\.vector), weights: groups[group].map(\.duration)) }
            let larger = own.filter { VoiceCoherence.cosine($0.vector, parts[0]) >= VoiceCoherence.cosine($0.vector, parts[1]) }
            let smaller = own.filter { VoiceCoherence.cosine($0.vector, parts[0]) < VoiceCoherence.cosine($0.vector, parts[1]) }
            let covered = [larger, smaller].map { VoiceCoherence.union($0.map(\.span)) }
            let passages = recording.segments.filter { $0.speakerID == speaker.id }
            let moved = passages.filter { segment in
                let span = VoiceCoherence.Span(start: segment.start, end: segment.end)
                return VoiceCoherence.overlap(span, with: covered[1]) > VoiceCoherence.overlap(span, with: covered[0])
            }
            // The 30 s also hold for the passages themselves: windows can cover a minute around a few
            // scattered words, which are interjections under another speaker, not a second person.
            measure.movedSeconds = moved.reduce(0) { $0 + $1.end - $1.start }
            guard moved.count < passages.count, (measure.movedSeconds ?? 0) >= Self.splitMinimumSeconds else { continue }
            let proposal = VoiceSplitProposal(speakerID: speaker.id, segmentIDs: moved.map(\.id), similarity: split.between)
            proposals.append(proposal)
            measure.proposed = true
            centroids[speaker.id] = VoiceCoherence.centroid(larger.map(\.vector), weights: larger.map(\.duration))
            windows[speaker.id] = larger
            minority[proposal.id] = (VoiceCoherence.centroid(smaller.map(\.vector), weights: smaller.map(\.duration)), VoiceCoherence.seconds(smaller.map(\.span)))
        }
        recording.splitProposals = proposals.isEmpty ? nil : proposals
    }

    /// Step 7. Diarization often cuts one person in several voices. Two voices of one track that
    /// sound alike are one person: the shorter joins the longer, and `separateSpeaker` undoes it.
    public mutating func mergeDuplicates() {
        let proposed = Set((recording.splitProposals ?? []).map(\.speakerID))
        func speech(_ id: UUID) -> Double { measures[id]?.speechSeconds ?? 0 }
        let eligible = recording.speakers.filter { !$0.ignored && centroids[$0.id] != nil && (measures[$0.id]?.embeddedSeconds ?? 0) >= Self.mergeMinimumSeconds }
        let ordered = eligible.sorted { speech($0.id) < speech($1.id) }
        for (position, voice) in ordered.enumerated() {
            let longer = ordered[(position + 1)...].filter { $0.source == voice.source }
            guard let best = longer.map({ ($0.id, VoiceCoherence.cosine(centroids[voice.id]!, centroids[$0.id]!)) }).max(by: { $0.1 < $1.1 }) else { continue }
            measures[voice.id]?.nearestLonger = best.0; measures[voice.id]?.nearestLongerCosine = best.1
            // A voice waiting for a split answer stays where it is: its proposal names it.
            guard best.1 >= Self.samePersonSimilarity, !proposed.contains(voice.id) else { continue }
            guard (try? recording.mergeSpeaker(voice.id, into: best.0)) != nil else { continue }
            if let index = recording.absorbedSpeakers?.firstIndex(where: { $0.id == voice.id }) { recording.absorbedSpeakers?[index].automatic = .merged }
        }
        // The smaller part of a proposal may itself be a voice that already exists.
        for index in (recording.splitProposals ?? []).indices {
            let proposal = recording.splitProposals![index]
            guard let part = minority[proposal.id], let source = recording.speakers.first(where: { $0.id == proposal.speakerID })?.source else { continue }
            let others = recording.speakers.filter { $0.id != proposal.speakerID && $0.source == source && !$0.ignored && centroids[$0.id] != nil }
            if let best = others.map({ ($0.id, VoiceCoherence.cosine(part.centroid, centroids[$0.id]!)) }).max(by: { $0.1 < $1.1 }),
               best.1 >= Self.samePersonSimilarity { recording.splitProposals![index].mergeInto = best.0 }
        }
    }

    /// One row to compare with voice memory: a voice, or the smaller part of a proposal.
    public struct Candidate: Sendable {
        public enum Key: Hashable, Sendable { case voice(UUID), proposal(UUID) }
        public var key: Key
        public var source: AudioSource
        public var vector: [Float]
    }

    /// Step 8, first half. Every voice still in play with enough speech, by its centroid.
    public var identificationCandidates: [Candidate] {
        var result: [Candidate] = []
        for speaker in recording.speakers where !speaker.ignored {
            guard let centroid = centroids[speaker.id], VoiceCoherence.seconds((windows[speaker.id] ?? []).map(\.span)) >= Self.identificationSeconds else { continue }
            result.append(.init(key: .voice(speaker.id), source: speaker.source, vector: centroid))
        }
        for proposal in recording.splitProposals ?? [] {
            guard let part = minority[proposal.id], part.seconds >= Self.identificationSeconds,
                  let source = recording.speakers.first(where: { $0.id == proposal.speakerID })?.source else { continue }
            result.append(.init(key: .proposal(proposal.id), source: source, vector: part.centroid))
        }
        return result
    }

    /// Step 8, second half. The app names the voice when it applies the result.
    public mutating func applyIdentities(_ matches: [Candidate.Key: VoiceMatch]) {
        for (key, match) in matches {
            switch key {
            case .voice(let id): if let index = recording.speakers.firstIndex(where: { $0.id == id }) { recording.speakers[index].proposedIdentity = match }
            case .proposal(let id): if let index = recording.splitProposals?.firstIndex(where: { $0.id == id }) { recording.splitProposals?[index].proposedIdentity = match }
            }
        }
    }

    /// Step 9. A voice with very little speech that nobody recognised is not worth a naming request:
    /// its text stays, under a shared label. Then the voices left to name are numbered again.
    public mutating func classify() {
        let heard = recording.speakers.filter { !$0.ignored }.reduce(0) { $0 + (measures[$1.id]?.speechSeconds ?? 0) }
        let language = SummaryLanguage.current
        var number = 0
        for index in recording.speakers.indices where !recording.speakers[index].ignored {
            let speaker = recording.speakers[index]
            let speech = measures[speaker.id]?.speechSeconds ?? 0
            if speaker.proposedIdentity == nil, !speaker.confirmed, speech < Self.minorSeconds, heard > 0, speech / heard < Self.minorShare {
                recording.speakers[index].automatic = .minor; recording.speakers[index].label = language.otherVoice
            } else { number += 1; recording.speakers[index].label = language.voiceLabel(number) }
        }
        for index in recording.speakers.indices where recording.speakers[index].ignored { number += 1; recording.speakers[index].label = language.voiceLabel(number) }
        for index in (recording.absorbedSpeakers ?? []).indices { number += 1; recording.absorbedSpeakers?[index].label = language.voiceLabel(number) }
    }
}

extension Recording {
    /// Proposals that still make sense: the voice exists and still holds some, not all, of the passages.
    public var pendingSplitProposals: [VoiceSplitProposal] {
        (splitProposals ?? []).filter { proposal in
            guard speakers.contains(where: { $0.id == proposal.speakerID && !$0.ignored }) else { return false }
            let named = Set(proposal.segmentIDs)
            let owned = segments.filter { $0.speakerID == proposal.speakerID }
            let held = owned.filter { named.contains($0.id) }.count
            return held > 0 && held < owned.count
        }
    }

    /// Passages of a proposal the voice still holds, and the other passages of that voice.
    public func splitParts(_ proposalID: UUID) -> (smaller: [TranscriptSegment], larger: [TranscriptSegment])? {
        guard let proposal = pendingSplitProposals.first(where: { $0.id == proposalID }) else { return nil }
        let named = Set(proposal.segmentIDs)
        let owned = segments.filter { $0.speakerID == proposal.speakerID }
        return (owned.filter { named.contains($0.id) }, owned.filter { !named.contains($0.id) })
    }

    /// The user agrees that the voice held two people: the smaller part becomes a new voice, which
    /// takes the person voice memory proposed for it, or joins the voice it sounds like.
    /// Transcript correction only: no voice print is read or written. Returns the voice holding the passages.
    @discardableResult
    public mutating func acceptSplit(_ proposalID: UUID, people: [VoicePerson] = []) throws -> UUID {
        guard let proposal = pendingSplitProposals.first(where: { $0.id == proposalID }) else { throw StoreError.notFound }
        splitProposals?.removeAll { $0.id == proposalID }
        if splitProposals?.isEmpty == true { splitProposals = nil }
        let voice = try moveToNewSpeaker(Set(proposal.segmentIDs), from: proposal.speakerID)
        if let target = proposal.mergeInto, speakers.contains(where: { $0.id == target && !$0.ignored }) {
            try mergeSpeaker(voice, into: target)
            return target
        }
        if let match = proposal.proposedIdentity { proposeIdentities([voice: match], people: people) }
        return voice
    }

    /// The user states the voice is one person: the proposal goes away.
    public mutating func dismissSplit(_ proposalID: UUID) throws {
        guard splitProposals?.contains(where: { $0.id == proposalID }) == true else { throw StoreError.notFound }
        splitProposals?.removeAll { $0.id == proposalID }
        if splitProposals?.isEmpty == true { splitProposals = nil }
        transcriptVersion += 1
    }

    /// The user wants a voice set aside as too brief back among the voices to name.
    public mutating func restoreMinorVoice(_ id: UUID) throws {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound }
        guard speakers[index].isMinor else { return }
        speakers[index].automatic = nil; speakers[index].label = nextVoiceLabel()
        transcriptVersion += 1
    }
}
