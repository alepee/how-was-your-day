import Foundation

/// A part of a session that one writer changes as a whole. Two writers that change different
/// parts never conflict; the same part changed on both sides keeps the local side.
public enum RecordingPart: String, CaseIterable, Sendable {
    case title, kind, notes, noteEntries, consent, language, calendar
    /// Capture state, duration and audio chunks.
    case capture
    /// Segments, voices, transcript state and provenance, and the transcript version.
    case transcript
    /// Summary text and provenance.
    case summary
    /// Start date and demo flag.
    case identity
}

extension Recording {
    /// Rebases `local`, edited from `base`, on `remote`, another writer's later commit. Each part
    /// takes the side that changed it since `base`; a part both sides changed differently keeps
    /// `local` and is reported. A summary is kept only with the transcript it was made from: when
    /// the transcript comes from `remote`, so does the summary. Revision and versions come from
    /// `remote`, so the result can be committed over it; a transcript both sides changed gets a new
    /// transcript version.
    ///
    /// `base` nil means `local` was never stored: every part of `local` counts as changed.
    public static func merge(base: Recording?, local: Recording, remote: Recording) -> (merged: Recording, conflicts: Set<RecordingPart>) {
        var merged = remote, conflicts = Set<RecordingPart>(), fromLocal = Set<RecordingPart>()
        func take(_ part: RecordingPart, _ value: (Recording) -> some Equatable, _ copy: (inout Recording, Recording) -> Void) {
            let localChanged = base.map { value($0) != value(local) } ?? true
            guard localChanged else { return }
            let remoteChanged = base.map { value($0) != value(remote) } ?? true
            if remoteChanged && value(remote) != value(local) { conflicts.insert(part) }
            copy(&merged, local); fromLocal.insert(part)
        }
        take(.title, \.title) { $0.title = $1.title }
        take(.kind, \.kind) { $0.kind = $1.kind }
        take(.notes, \.notes) { $0.notes = $1.notes }
        take(.noteEntries, \.noteEntries) { $0.noteEntries = $1.noteEntries }
        take(.consent, \.consentAnnounced) { $0.consentAnnounced = $1.consentAnnounced }
        take(.language, \.speechLanguage) { $0.speechLanguage = $1.speechLanguage }
        take(.calendar, \.calendarContext) { $0.calendarContext = $1.calendarContext }
        take(.capture, { CaptureParts(state: $0.state, duration: $0.duration, chunks: $0.audioChunks) }) {
            $0.state = $1.state; $0.duration = $1.duration; $0.audioChunks = $1.audioChunks
        }
        take(.transcript, TranscriptParts.init) {
            $0.speakers = $1.speakers; $0.absorbedSpeakers = $1.absorbedSpeakers; $0.segments = $1.segments
            $0.transcriptVersion = $1.transcriptVersion; $0.transcriptState = $1.transcriptState; $0.transcription = $1.transcription
        }
        // Both changed the transcript: the kept one gets a version neither side used, so work that
        // read the other side's transcript is not taken for current.
        if conflicts.contains(.transcript) { merged.transcriptVersion = max(local.transcriptVersion, remote.transcriptVersion) + 1 }
        let remoteTranscript = !fromLocal.contains(.transcript) && base.map { TranscriptParts($0) != TranscriptParts(remote) } == true
        if !remoteTranscript {
            take(.summary, { SummaryParts(text: $0.summary, provenance: $0.summaryProvenance) }) {
                $0.summary = $1.summary; $0.summaryProvenance = $1.summaryProvenance
            }
        }
        take(.identity, { IdentityParts(startedAt: $0.startedAt, isDemo: $0.isDemo) }) {
            $0.startedAt = $1.startedAt; $0.isDemo = $1.isDemo
        }
        return (merged, conflicts)
    }
}

private struct CaptureParts: Equatable { var state: CaptureState; var duration: Double; var chunks: [AudioChunk] }
private struct SummaryParts: Equatable { var text: String?; var provenance: SummaryProvenance? }
private struct IdentityParts: Equatable { var startedAt: Date; var isDemo: Bool }
private struct TranscriptParts: Equatable {
    var speakers: [Speaker], absorbed: [Speaker]?, segments: [TranscriptSegment]
    var version: Int, state: ArtifactState, provenance: TranscriptionProvenance?
    init(_ item: Recording) {
        speakers = item.speakers; absorbed = item.absorbedSpeakers; segments = item.segments
        version = item.transcriptVersion; state = item.transcriptState; provenance = item.transcription
    }
}
