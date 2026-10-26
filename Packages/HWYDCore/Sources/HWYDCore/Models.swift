import Foundation

public enum SessionKind: String, Codable, CaseIterable, Sendable {
    case meeting, call, conversation, voiceMemo = "voice-memo", adHoc = "ad-hoc"
    public var label: String {
        switch self { case .meeting: "Réunion"; case .call: "Appel"; case .conversation: "Conversation"; case .voiceMemo: "Mémo vocal"; case .adHoc: "Session libre" }
    }
    public var symbol: String {
        switch self { case .meeting: "person.2.wave.2"; case .call: "phone"; case .conversation: "bubble.left.and.bubble.right"; case .voiceMemo: "waveform"; case .adHoc: "record.circle" }
    }
}
public enum CaptureState: String, Codable, Sendable { case recording, sealed, interrupted, demo }
public enum ArtifactState: String, Codable, Sendable { case unavailable, pending, ready, failed }
public enum AudioSource: String, Codable, Sendable { case mic, system }
public struct Speaker: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var label: String
    public var personID: UUID?
    public var proposedIdentity: VoiceMatch?
    public var confirmed: Bool
    public var source: AudioSource
    public init(id: UUID = UUID(), label: String, confirmed: Bool = false, source: AudioSource = .mic) {
        self.id = id; self.label = label; self.confirmed = confirmed; self.source = source
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
    public init(id: UUID = UUID(), start: Double, end: Double, speakerID: UUID?, source: AudioSource, text: String) {
        self.id = id; self.start = start; self.end = end; self.speakerID = speakerID; self.source = source; self.text = text
    }
}
public struct NoteEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var offset: Double
    public var text: String
    public init(id: UUID = UUID(), offset: Double, text: String = "") { self.id = id; self.offset = offset; self.text = text }
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
    public var segments: [TranscriptSegment]
    public var summaryProvenance: SummaryProvenance?
    public var summary: String?
    public var calendarContext: CalendarContext?
    public var transcription: TranscriptionProvenance?
    public var transcriptState: ArtifactState
    public var audioChunks: [AudioChunk]
    public var consentAnnounced: Bool
    public var isDemo: Bool
    public init(id: UUID = UUID(), title: String, kind: SessionKind = .adHoc, startedAt: Date = Date(), duration: Double = 0,
                state: CaptureState = .sealed, notes: String = "", noteEntries: [NoteEntry] = [], speakers: [Speaker] = [],
                segments: [TranscriptSegment] = [], summary: String? = nil, isDemo: Bool = false) {
        self.id = id; self.title = title; self.kind = kind; self.startedAt = startedAt; self.duration = duration
        self.state = state; self.revision = 0; self.transcriptVersion = segments.isEmpty ? 0 : 1
        self.notes = notes; self.noteEntries = noteEntries; self.speakers = speakers; self.segments = segments
        self.summary = summary; self.transcriptState = segments.isEmpty ? .unavailable : .ready
        self.audioChunks = []; self.consentAnnounced = false; self.isDemo = isDemo
    }
    /// One representative per confirmed person, while preserving all acoustic clusters.
    /// Unlinked names remain distinct: equal labels do not prove equal identity.
    public var participants: [Speaker] {
        var seen = Set<UUID>()
        return speakers.filter { $0.confirmed && seen.insert($0.personID ?? $0.id).inserted }
    }
    public var participantNames: String {
        let names = participants.map(\.label)
        let unknown = speakers.filter { !$0.confirmed }.count
        return (names + (unknown > 0 ? ["\(unknown) voix à nommer"] : [])).joined(separator: ", ")
    }
    public var searchableText: String { ([title, notes, summary ?? ""] + segments.map(\.text) + speakers.map(\.label)).joined(separator: " ") }
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
        summary = nil
    }
    public mutating func renameSpeaker(_ id: UUID, to label: String) throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else { throw StoreError.invalidName }
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound }
        speakers[index].label = trimmed; speakers[index].confirmed = true; speakers[index].personID = nil; speakers[index].proposedIdentity = nil
        transcriptVersion += 1; summary = nil
    }
}
public enum StoreError: LocalizedError, Equatable {
    case notFound, conflict, invalidName, invalidPath, incompatibleSpeaker
    public var errorDescription: String? {
        switch self {
        case .notFound: "Cette session n’est plus disponible."
        case .conflict: "Cette session a été modifiée ailleurs. Rechargez-la avant de réessayer."
        case .invalidName: "Saisissez un nom de 1 à 120 caractères."
        case .incompatibleSpeaker: "Cette voix appartient à une autre piste audio."
        case .invalidPath: "Le chemin du fichier audio n’est pas valide."
        }
    }
}
public func timeLabel(_ seconds: Double, hours: Bool = false) -> String {
    let value = max(0, Int(seconds.isFinite ? seconds : 0))
    if hours || value >= 3600 { return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
    return String(format: "%02d:%02d", value / 60, value % 60)
}
