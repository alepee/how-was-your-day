import Combine
import Foundation

/// What the user asked to record.
public struct CaptureRequest: Equatable, Sendable {
    public var kind: SessionKind
    /// The name typed on the setup screen; blank falls back to a default.
    public var title: String?
    /// A calendar meeting gives its own kind and title.
    public var meeting: CalendarContext?
    /// A locale or `SpeechLanguage.automatic`; automatic when nil.
    public var language: String?

    public init(kind: SessionKind = .adHoc, title: String? = nil, meeting: CalendarContext? = nil, language: String? = nil) {
        self.kind = kind; self.title = title; self.meeting = meeting; self.language = language
    }

    public var sessionKind: SessionKind { meeting == nil ? kind : .meeting }

    /// The typed name, else the meeting's title, else the kind and the time the session started.
    public func sessionTitle(startingAt date: Date) -> String {
        let typed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !typed.isEmpty { return typed }
        if let meeting { return meeting.title }
        let time = date.formatted(date: .omitted, time: .shortened)
        let kind = sessionKind
        return kind == .adHoc ? String(localized: "Session du \(time)", bundle: .hwyd) : String(localized: "\(kind.label) du \(time)", bundle: .hwyd)
    }
}

/// Where the capture stands. The session id is the recording being captured.
public enum CapturePhase: Equatable, Sendable {
    case idle
    case starting
    case recording(UUID)
    case paused(UUID)
    /// The devices are stopping and the audio is being sealed.
    case stopping(UUID)

    public var sessionID: UUID? {
        switch self {
        case .idle, .starting: nil
        case .recording(let id), .paused(let id), .stopping(let id): id
        }
    }
}

public struct CaptureLevels: Equatable, Sendable {
    public var mic: Float
    public var system: Float
    public init(mic: Float, system: Float) { self.mic = mic; self.system = system }
    public static let silent = CaptureLevels(mic: 0, system: 0)
}

/// Why a capture ended.
public enum CaptureStop: Equatable, Sendable {
    case requested
    /// The Mac is going to sleep. The capture does not resume on wake.
    case systemSleep
    case failed(CaptureFault)
}

public struct CaptureEnding: Equatable, Sendable {
    public var sessionID: UUID
    public var cause: CaptureStop
    public var finalizationError: String?
}

/// One capture at a time, from the request to the end of the session: the session clock, pause
/// and resume, the default title, what ends a capture (the user, sleep, a fault) and what follows
/// it. The audio comes from an `AudioCapture` given at each start.
///
/// The session clock counts recorded time: it stops while paused and skips the restarts of the
/// microphone stream, like the audio timeline, so notes taken during the session stay aligned
/// with the audio.
///
/// After a capture with audio, the session's transcription is requested at once and waits its
/// turn behind other work. A simulation is never transcribed.
@MainActor
public final class CaptureSession: ObservableObject {
    @Published public private(set) var phase: CapturePhase = .idle
    /// The meters, silent unless recording.
    @Published public private(set) var levels: CaptureLevels = .silent
    /// Called for every capture that ended, whatever ended it, before the transcription is requested.
    public var onEnd: ((CaptureEnding) -> Void)?

    private let notifier: any UserNotifier
    private let transcribe: @MainActor (UUID) async -> WorkDecision
    private let now: @MainActor () -> TimeInterval
    private var capture: (any AudioCapture)?
    private var library: SessionLibrary?
    private var listener: Task<Void, Never>?
    private var clock = SessionClock()
    /// When the clock froze for a restart of the microphone stream.
    private var restartFrozenAt: TimeInterval?

    /// - Parameters:
    ///   - transcribe: requests a session's transcription; the decision says whether it starts or waits.
    ///   - now: a monotonic time in seconds.
    public init(notifier: any UserNotifier, transcribe: @escaping @MainActor (UUID) async -> WorkDecision,
                now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.notifier = notifier; self.transcribe = transcribe; self.now = now
    }

    public var sessionID: UUID? { phase.sessionID }
    public var isPaused: Bool { if case .paused = phase { true } else { false } }
    public var isStarting: Bool { phase == .starting }
    /// Recorded time of the running capture, in seconds.
    public var elapsed: TimeInterval { clock.elapsed(at: now()) }

    /// Starts `capture` and adds its session to `library`. Returns nil when a capture already runs
    /// or starts. Throws when the capture cannot start; no session is added then.
    @discardableResult
    public func start(_ request: CaptureRequest, with capture: any AudioCapture, in library: SessionLibrary) async throws -> UUID? {
        guard phase == .idle else { return nil }
        phase = .starting
        let id = UUID()
        let title = request.sessionTitle(startingAt: Date())
        do { try await capture.start(session: id) } catch { phase = .idle; throw error }
        self.capture = capture; self.library = library
        var item = Recording(id: id, title: title, kind: request.sessionKind, state: .recording, isDemo: capture.isSimulated)
        if !capture.isSimulated { item.calendarContext = request.meeting; item.speechLanguage = request.language ?? SpeechLanguage.automatic }
        library.insert(item)
        clock = SessionClock(); clock.run(at: now()); restartFrozenAt = nil
        phase = .recording(id)
        let events = capture.events
        listener = Task { [weak self] in
            for await event in events { self?.handle(event, session: id) }
        }
        if !capture.isSimulated { await library.flush() }
        return id
    }

    /// Stops the devices; the clock and the audio timeline skip the pause. A restart in progress
    /// keeps its start, so that its end still corrects the clock.
    public func pause() async {
        guard case .recording(let id) = phase, let capture else { return }
        clock.freeze(at: now())
        phase = .paused(id); levels = .silent
        await capture.pause()
    }

    /// Resumes a paused capture. A failure is reported and the capture stays paused.
    public func resume() async {
        guard case .paused(let id) = phase, let capture else { return }
        do { try await capture.resume() } catch {
            notifier.notify(.error(error.localizedDescription)); return
        }
        guard phase == .paused(id) else { return }
        clock.run(at: now())
        phase = .recording(id)
    }

    /// Ends the capture: the session is sealed, or interrupted after a fault, with the audio
    /// recorded so far. Then its transcription is requested, unless it holds no audio or is a
    /// simulation. Returns nil when no capture runs or it is already stopping.
    @discardableResult
    public func stop(_ cause: CaptureStop = .requested) async -> CaptureEnding? {
        guard let id = phase.sessionID, phase != .stopping(id), let capture, let library else { return nil }
        let duration = elapsed
        clock.freeze(at: now())
        phase = .stopping(id); levels = .silent
        listener?.cancel(); listener = nil
        let audio = await capture.stop()
        self.capture = nil; self.library = nil
        let interrupted = audio.finalizationError != nil || { if case .failed = cause { true } else { false } }()
        library.edit(id) { $0.duration = duration; $0.state = interrupted ? .interrupted : .sealed; $0.audioChunks = audio.chunks }
        phase = .idle
        clock = SessionClock()
        if let error = audio.finalizationError { notifier.notify(.error(error)) }
        if capture.isSimulated { notifier.notify(.info(String(localized: "Simulation terminée. Les notes restent disponibles.", bundle: .hwyd))) }
        else if audio.chunks.isEmpty { notifier.notify(.info(String(localized: "Aucun audio reçu. Vos notes sont conservées.", bundle: .hwyd))) }
        if case .failed(let fault) = cause { notifier.notify(.error(fault.message)) }
        let ending = CaptureEnding(sessionID: id, cause: cause, finalizationError: audio.finalizationError)
        onEnd?(ending)
        if !capture.isSimulated, !audio.chunks.isEmpty {
            // Waits its turn behind other work; the window may be closed, so say which.
            switch await transcribe(id) {
            case .accepted: notifier.notify(.info(String(localized: "Audio et notes conservés. La transcription locale va démarrer.", bundle: .hwyd)))
            case .queued: notifier.notify(.info(String(localized: "Audio et notes conservés. La transcription démarrera après le traitement en cours.", bundle: .hwyd)))
            case .refused: break
            }
        }
        return ending
    }

    /// A capture does not survive sleep: the session ends with what was recorded.
    @discardableResult
    public func systemWillSleep() async -> CaptureEnding? { await stop(.systemSleep) }

    /// Stops the devices and forgets the capture without ending its session: for a simulation
    /// whose volatile library is being dropped.
    public func discard() async {
        guard let capture, let id = phase.sessionID, phase != .stopping(id) else { return }
        listener?.cancel(); listener = nil
        self.capture = nil; library = nil
        phase = .idle; levels = .silent; clock = SessionClock()
        _ = await capture.stop()
    }

    func handle(_ event: CaptureEvent, session id: UUID) {
        guard phase.sessionID == id else { return }
        switch event {
        case .levels(let mic, let system):
            if phase == .recording(id) { levels = CaptureLevels(mic: mic, system: system) }
        case .restarting:
            guard phase == .recording(id) else { return }
            let time = now()
            clock.freeze(at: time); restartFrozenAt = time
        case .restarted(let gap):
            // The clock ran from the start of the restart until it froze, and stood still from
            // the end of the restart until now: both are corrected so that it skips `gap` exactly.
            let time = now()
            let frozen = restartFrozenAt.map { time - $0 } ?? 0
            restartFrozenAt = nil
            clock.shift(by: frozen - gap)
            if phase == .recording(id) { clock.run(at: time) }
        case .failed(let fault):
            // Stopping cancels this listener: the stop runs on its own.
            Task { await stop(.failed(fault)) }
        }
    }
}

/// Recorded time: runs while recording, stands still otherwise.
struct SessionClock {
    private var banked: TimeInterval = 0
    private var runningSince: TimeInterval?
    func elapsed(at now: TimeInterval) -> TimeInterval { banked + (runningSince.map { max(0, now - $0) } ?? 0) }
    mutating func run(at now: TimeInterval) { if runningSince == nil { runningSince = now } }
    mutating func freeze(at now: TimeInterval) { banked = elapsed(at: now); runningSince = nil }
    mutating func shift(by seconds: TimeInterval) { banked = max(0, banked + seconds) }
}
