import Foundation

public enum SessionKind: String, Codable, CaseIterable, Sendable {
    case voiceMemo = "voice-memo", exchange, meeting
    /// Reads the current kinds and the ones earlier versions stored: a call, a conversation and an
    /// ad-hoc session are exchanges.
    public init?(rawValue: String) {
        switch rawValue {
        case "voice-memo": self = .voiceMemo
        case "exchange", "call", "conversation", "ad-hoc": self = .exchange
        case "meeting": self = .meeting
        default: return nil
        }
    }
    public var label: String {
        switch self { case .voiceMemo: String(localized: "Mémo", bundle: .hwyd); case .exchange: String(localized: "Échange", bundle: .hwyd); case .meeting: String(localized: "Réunion", bundle: .hwyd) }
    }
    public var symbol: String {
        switch self { case .voiceMemo: "waveform.circle"; case .exchange: "bubble.left.and.bubble.right"; case .meeting: "person.2.wave.2" }
    }
    /// Whether other people may be recorded, so their consent is asked before the capture starts.
    public var involvesOthers: Bool { self != .voiceMemo }
}
public enum CaptureState: String, Codable, Sendable { case recording, sealed, interrupted, demo }
public enum ArtifactState: String, Codable, Sendable { case unavailable, pending, ready, failed }
public enum AudioSource: String, Codable, Sendable { case mic, system }
/// What the voice post-processing decided for a voice. The user can always undo it.
public enum AutomaticVoiceDecision: String, Codable, Equatable, Sendable {
    /// Microphone voice heard almost only while the other track speaks: the call picked up by the microphone.
    case echo
    /// Too little speech to be a participant worth naming.
    case minor
    /// Same person as a longer voice of the same track, merged into it.
    case merged
}
public struct Speaker: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var personID: UUID?
    public var proposedIdentity: VoiceMatch?
    public var confirmed: Bool
    public var source: AudioSource
    /// A voice that is not a participant (speaker echo, noise): set by the user, or by the voice
    /// post-processing for a probable echo (`automatic` then says so).
    /// Its segments stay stored but leave the transcript, exports, search and summaries.
    public var ignored: Bool = false
    /// Decision of the voice post-processing still in force. Nil once the user overrides it.
    public var automatic: AutomaticVoiceDecision?
    /// A voice with too little speech to be named: its text stays, it is not a participant.
    public var isMinor: Bool { automatic == .minor }
    public init(id: UUID = UUID(), label: String, confirmed: Bool = false, source: AudioSource = .mic) {
        self.id = id; self.label = label; self.confirmed = confirmed; self.source = source
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); label = try c.decode(String.self, forKey: .label)
        personID = try c.decodeIfPresent(UUID.self, forKey: .personID)
        proposedIdentity = try c.decodeIfPresent(VoiceMatch.self, forKey: .proposedIdentity)
        confirmed = try c.decode(Bool.self, forKey: .confirmed); source = try c.decode(AudioSource.self, forKey: .source)
        ignored = try c.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
        automatic = try c.decodeIfPresent(AutomaticVoiceDecision.self, forKey: .automatic)
    }
}
public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var speakerID: UUID?
    public var source: AudioSource
    public var text: String
    public var words: [TranscriptWord]?
    /// nil means not evaluated; true is a cross-track repetition hint, not proven echo.
    public var echoSuspect: Bool?
    /// Voice detected for this segment before the user merged it into another one. Allows separating them again.
    public var originalSpeakerID: UUID?
    public init(id: UUID = UUID(), start: Double, end: Double, speakerID: UUID?, source: AudioSource, text: String) {
        self.id = id; self.start = start; self.end = end; self.speakerID = speakerID; self.source = source; self.text = text
    }
}
public struct NoteEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var offset: Double
    /// The note, or the caption of `image`.
    public var text: String
    /// An image pasted during the capture. Absent from sessions recorded before images existed.
    public var image: NoteImage?
    public init(id: UUID = UUID(), offset: Double, text: String = "", image: NoteImage? = nil) {
        self.id = id; self.offset = offset; self.text = text; self.image = image
    }
}
/// An image kept with the notes. Its PNG lives in the data directory (`NoteImageFiles`), never in SQLite.
public struct NoteImage: Codable, Equatable, Sendable {
    public var id: UUID
    public var width: Int
    public var height: Int
    public init(id: UUID = UUID(), width: Int, height: Int) { self.id = id; self.width = width; self.height = height }
}
public struct AudioChunk: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var source: AudioSource
    public var relativePath: String
    public var start: Double
    public var duration: Double
    public init(id: UUID = UUID(), source: AudioSource, relativePath: String, start: Double, duration: Double) {
        self.id = id; self.source = source; self.relativePath = relativePath; self.start = start; self.duration = duration
    }
}
/// Why the capture changed at a boundary.
public enum CaptureBoundaryReason: String, Codable, Sendable {
    /// Recording resumed in a session that had ended.
    case resumed
    /// The user chose another microphone during the recording.
    case user
    /// The user accepted a microphone the system proposed.
    case accepted
    /// The microphone in use disappeared and the system default input took over.
    case forced
}
/// A point of the session's timeline where the capture changed: recording resumed, or another
/// microphone took over. The acoustic path may differ on each side.
public struct CaptureBoundary: Codable, Equatable, Sendable {
    /// Recorded seconds on the session's timeline where the new audio starts.
    public var offset: Double
    /// Wall-clock time of the boundary.
    public var at: Date
    public var reason: CaptureBoundaryReason
    /// Name of the input device used from this boundary on, when the capture could tell.
    public var microphone: String?
    public init(offset: Double, at: Date, reason: CaptureBoundaryReason, microphone: String? = nil) {
        self.offset = offset; self.at = at; self.reason = reason; self.microphone = microphone
    }
}
public struct Recording: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: SessionKind
    public var startedAt: Date
    public var duration: Double
    public var state: CaptureState
    public var revision: Int
    public var transcriptVersion: Int
    public var notesVersion: Int?
    public var summaryVersion: Int?
    public var notes: String
    public var noteEntries: [NoteEntry]
    public var speakers: [Speaker]
    /// Voices merged into another one on the same track, kept so the merge can be undone.
    public var absorbedSpeakers: [Speaker]?
    /// Voices the post-processing found to hold two people, waiting for the user's answer.
    public var splitProposals: [VoiceSplitProposal]?
    public var segments: [TranscriptSegment]
    public var summaryProvenance: SummaryProvenance?
    public var summary: String?
    public var calendarContext: CalendarContext?
    public var transcription: TranscriptionProvenance?
    public var transcriptState: ArtifactState
    public var audioChunks: [AudioChunk]
    public var consentAnnounced: Bool
    /// When the user declared the people present informed and agreeing. Nil when not declared,
    /// and in sessions declared before this field existed.
    public var consentAnnouncedAt: Date?
    public var isDemo: Bool
    /// Transcription language requested for this session: a locale or `SpeechLanguage.automatic`.
    /// Absent in sessions recorded before 0.11.0, which were transcribed in French.
    public var speechLanguage: String?
    /// Wall-clock time the last capture of the session stopped. Absent in sessions that ended before this field existed.
    public var endedAt: Date?
    /// Where the capture changed on the session's timeline (recording resumed, microphone
    /// changed), oldest first. Nil when it never did.
    public var boundaries: [CaptureBoundary]?
    /// Name of the microphone the session started on. Absent in sessions recorded before this
    /// field existed, and when the capture could not tell.
    public var microphone: String?
    public init(id: UUID = UUID(), title: String, kind: SessionKind = .exchange, startedAt: Date = Date(), duration: Double = 0,
                state: CaptureState = .sealed, notes: String = "", noteEntries: [NoteEntry] = [], speakers: [Speaker] = [],
                segments: [TranscriptSegment] = [], summary: String? = nil, isDemo: Bool = false) {
        self.id = id; self.title = title; self.kind = kind; self.startedAt = startedAt; self.duration = duration
        self.state = state; self.revision = 0; self.transcriptVersion = segments.isEmpty ? 0 : 1
        self.notes = notes; self.noteEntries = noteEntries; self.speakers = speakers; self.segments = segments
        self.summary = summary; self.transcriptState = segments.isEmpty ? .unavailable : .ready
        self.audioChunks = []; self.consentAnnounced = false; self.isDemo = isDemo
    }
    /// When the session ended: the stop of its last capture, else its start plus its recorded
    /// duration, which leaves pauses out and can be earlier than the real end.
    public var endDate: Date { endedAt ?? startedAt.addingTimeInterval(duration) }
    /// One representative per confirmed person, while preserving all acoustic clusters.
    /// Unlinked names remain distinct: equal labels do not prove equal identity.
    public var participants: [Speaker] {
        var seen = Set<UUID>()
        return speakers.filter { $0.confirmed && !$0.ignored && seen.insert($0.personID ?? $0.id).inserted }
    }
    public var participantNames: String {
        let names = participants.map(\.label)
        let unknown = speakers.filter { !$0.confirmed && !$0.ignored && !$0.isMinor }.count
        return (names + (unknown > 0 ? [String(localized: "\(unknown) voix à nommer", bundle: .hwyd)] : [])).joined(separator: ", ")
    }
    public var searchableText: String { ([title, notes, summary ?? ""] + heardSegments.map(\.text) + speakers.filter { !$0.ignored }.map(\.label)).joined(separator: " ") }
    /// Segments of every voice the user did not ignore. Unattributed segments are kept.
    public var heardSegments: [TranscriptSegment] {
        let ignored = Set(speakers.lazy.filter(\.ignored).map(\.id))
        return ignored.isEmpty ? segments : segments.filter { $0.speakerID.map { !ignored.contains($0) } ?? true }
    }
    /// Every voice worth naming is named or confirmed: no unidentified voice, no pending proposal,
    /// no voice suspected of holding two people.
    public var voicesResolved: Bool { speakers.allSatisfy { $0.ignored || $0.confirmed || $0.isMinor } && pendingSplitProposals.isEmpty }
    /// Ready for an automatic summary: transcript done, speech heard, every voice resolved, no summary yet.
    public var isReadyForSummary: Bool {
        !isDemo && state != .recording && transcriptState == .ready && summary == nil && voicesResolved
            && heardSegments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    /// The summary was made from an earlier transcript: a correction or a new transcription came since.
    /// Corrections keep the summary; regenerating it is the user's decision. A summary saved without
    /// provenance predates this rule, when every correction removed it, so it is taken as current.
    public var summaryIsStale: Bool {
        guard summary != nil, let provenance = summaryProvenance else { return false }
        return provenance.transcriptVersion != transcriptVersion
    }
    /// Copy whose segments exclude ignored voices, for exports, search and summaries.
    public var withoutIgnoredVoices: Recording { var copy = self; copy.segments = heardSegments; return copy }
    /// Correct this segment only. Naming and biometric enrollment are separate actions.
    public mutating func assignSpeaker(_ speakerID: UUID?, to segmentID: UUID) throws {
        guard let index = segments.firstIndex(where: { $0.id == segmentID }) else { throw StoreError.notFound }
        if let speakerID {
            guard let speaker = speakers.first(where: { $0.id == speakerID }) else { throw StoreError.notFound }
            guard speaker.source == segments[index].source else { throw StoreError.incompatibleSpeaker }
        }
        guard segments[index].speakerID != speakerID else { return }
        segments[index].speakerID = speakerID
        transcriptVersion += 1
    }
    public mutating func renameSpeaker(_ id: UUID, to label: String) throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { throw StoreError.invalidName }
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound }
        speakers[index].label = trimmed; speakers[index].confirmed = true; speakers[index].personID = nil; speakers[index].proposedIdentity = nil
        speakers[index].automatic = nil
        transcriptVersion += 1
    }
}
public enum StoreError: LocalizedError, Equatable {
    case notFound, conflict, invalidName, invalidPath, incompatibleSpeaker, capturing
    public var errorDescription: String? {
        switch self {
        case .notFound: String(localized: "Cette session n’est plus disponible.", bundle: .hwyd)
        case .conflict: String(localized: "Cette session a été modifiée ailleurs. Rechargez-la avant de réessayer.", bundle: .hwyd)
        case .invalidName: String(localized: "Saisissez un nom de 1 à 120 caractères.", bundle: .hwyd)
        case .incompatibleSpeaker: String(localized: "Cette voix appartient à une autre piste audio.", bundle: .hwyd)
        case .invalidPath: String(localized: "Le chemin du fichier audio n’est pas valide.", bundle: .hwyd)
        case .capturing: String(localized: "Cette session est en cours d’enregistrement.", bundle: .hwyd)
        }
    }
}
public func timeLabel(_ seconds: Double, hours: Bool = false) -> String {
    let value = max(0, Int(seconds.isFinite ? seconds : 0))
    if hours || value >= 3600 { return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
    return String(format: "%02d:%02d", value / 60, value % 60)
}
