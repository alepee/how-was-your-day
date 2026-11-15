import Foundation

/// Where a capture continues on a session's timeline: a new session starts at zero, a resumed
/// one after the audio and the time it already holds.
public struct CaptureContinuation: Equatable, Sendable {
    /// Seconds on the session's timeline where the first new chunk starts, on a 16 kHz frame.
    public var offset: Double
    /// File sequence number of the first new chunk pair (`mic-NNNNNN.caf`, `system-NNNNNN.caf`),
    /// so no earlier file is written over.
    public var firstSequence: Int

    public init(offset: Double = 0, firstSequence: Int = 0) { self.offset = offset; self.firstSequence = firstSequence }

    /// A new session.
    public static let start = CaptureContinuation()

    /// Sample rate of the audio timeline.
    public static let frameRate = 16000.0

    /// After everything `recording` holds: its recorded duration and the end of its last chunk,
    /// whichever is later, so new chunks never overlap earlier audio and notes stay after earlier
    /// notes. The sequence is one past the highest chunk file the session records.
    public init(after recording: Recording) {
        let durationFrames = Int64((recording.duration * Self.frameRate - 1e-6).rounded(.up))
        let audioFrames = recording.audioChunks.map { Int64((($0.start + $0.duration) * Self.frameRate).rounded()) }.max() ?? 0
        offset = Double(max(0, durationFrames, audioFrames)) / Self.frameRate
        firstSequence = (recording.audioChunks.compactMap { Self.sequence(ofFile: $0.relativePath) }.max() ?? -1) + 1
    }

    /// The offset in 16 kHz frames.
    public var offsetFrames: Int64 { Int64((offset * Self.frameRate).rounded()) }

    /// The sequence number of a chunk or descriptor file name (`mic-000003.caf`,
    /// `system-000003.partial.caf`, `000003.json`), nil for any other name.
    public static func sequence(ofFile path: String) -> Int? {
        let name = (path as NSString).lastPathComponent
        guard let match = name.firstMatch(of: /^(?:(?:mic|system)-)?([0-9]{6})(?:\.partial)?\.(?:caf|json)$/) else { return nil }
        return Int(match.1)
    }

    /// One past the highest sequence of the files already in `folder`, 0 when there are none:
    /// even a file the session does not record (a pair recovery skipped) is never written over.
    public static func firstFreeSequence(in folder: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return (names.compactMap(sequence(ofFile:)).max() ?? -1) + 1
    }
}

/// Why recording cannot resume in a session.
public enum ResumeRefusal: LocalizedError, Equatable, Sendable {
    /// An example, or a session recorded by a simulation.
    case example
    /// The session is being recorded.
    case recording
    /// The session ended more than `SessionResume.window` ago.
    case tooLate
    /// Another capture runs or starts.
    case captureRunning
    /// A summary or voice job runs or waits on the session.
    case busy(WorkJob)

    /// The action is not offered at all; otherwise it is shown, disabled, with the reason.
    public var hidesAction: Bool {
        switch self {
        case .example, .recording, .tooLate: true
        case .captureRunning, .busy: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .example: String(localized: "Les exemples ne peuvent pas reprendre l’enregistrement.", bundle: .hwyd)
        case .recording: String(localized: "Cette session est en cours d’enregistrement.", bundle: .hwyd)
        case .tooLate: String(localized: "L’enregistrement ne peut reprendre que dans les 24 heures qui suivent la fin de la session.", bundle: .hwyd)
        case .captureRunning: String(localized: "Une capture est déjà en cours.", bundle: .hwyd)
        case .busy(let job): (WorkBusy(job: job).errorDescription ?? "") + " " + String(localized: "Réessayez une fois ce traitement terminé.", bundle: .hwyd)
        }
    }
}

/// When recording can continue in a session that has ended, and where its resumes show.
public enum SessionResume {
    /// How long after its end a session can be resumed.
    public static let window: TimeInterval = 24 * 3600

    /// Why recording cannot resume in `recording` now, nil when it can.
    /// - Parameters:
    ///   - captureIdle: no capture runs or starts.
    ///   - jobs: the work that runs or waits on this session. A transcription does not prevent
    ///     resuming: the caller cancels it, since the session is transcribed again at the end.
    public static func refusal(for recording: Recording, now: Date, captureIdle: Bool, jobs: [WorkJob] = []) -> ResumeRefusal? {
        if recording.isDemo || recording.state == .demo { return .example }
        if recording.state == .recording { return .recording }
        if now.timeIntervalSince(recording.endDate) > window { return .tooLate }
        if !captureIdle { return .captureRunning }
        if let job = jobs.first(where: { $0.sessionID == recording.id && $0.kind != .transcription }) { return .busy(job) }
        return nil
    }

    /// The resumes to mark before each segment: only `resumed` boundaries are marked, each before
    /// the first of `segments` that starts at or after its offset. A resume after every segment has
    /// no marker. `segments` must be in transcript order.
    public static func markers(_ boundaries: [CaptureBoundary]?, before segments: [TranscriptSegment]) -> [UUID: [CaptureBoundary]] {
        var result: [UUID: [CaptureBoundary]] = [:]
        for resume in (boundaries ?? []).filter({ $0.reason == .resumed }).sorted(by: { $0.offset < $1.offset }) {
            if let segment = segments.first(where: { $0.start >= resume.offset }) { result[segment.id, default: []].append(resume) }
        }
        return result
    }

    /// The marker as the transcript shows it: « Reprise à 14:32 », in the user's time zone.
    public static func label(_ resume: CaptureBoundary) -> String {
        String(localized: "Reprise à \(resume.at.formatted(date: .omitted, time: .shortened))", bundle: .hwyd)
    }

    /// The marker in exports and in what a summary reads: French and a fixed 24-hour time, like the
    /// rest of the exported transcript, in `timeZone`.
    public static func exportLabel(_ resume: CaptureBoundary, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: resume.at)
        return String(format: "Reprise à %02d:%02d", parts.hour ?? 0, parts.minute ?? 0) // l10n:ignore
    }
}
