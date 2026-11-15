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
    /// UID of the microphone the user chose on the setup screen; nil records the system default input.
    public var microphone: String?

    public init(kind: SessionKind = .adHoc, title: String? = nil, meeting: CalendarContext? = nil, language: String? = nil, microphone: String? = nil) {
        self.kind = kind; self.title = title; self.meeting = meeting; self.language = language; self.microphone = microphone
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

/// A microphone the system proposed while recording: the system default input moved to it.
/// It waits for the user's answer; no answer keeps the microphone in use.
public struct MicrophoneOffer: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var device: MicrophoneDevice
    /// Name of the microphone in use, kept if the user declines.
    public var current: String?
    public init(device: MicrophoneDevice, current: String?) { self.device = device; self.current = current }
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
///
/// Recording can also continue in a session that ended (`continueRecording`): the new audio and
/// the clock follow what the session already holds, and the resume is recorded in it.
///
/// The microphone is a choice: the capture records the one asked for, and changes it only when
/// the user chooses another (`chooseMicrophone`), accepts the one the system proposes
/// (`acceptOffer`), or when it disappears; then the system default input takes over and the user
/// is told, or the session is interrupted when no input is left. Each change records a boundary
/// in the session. The last microphone the user chose is remembered in the settings.
@MainActor
public final class CaptureSession: ObservableObject {
    @Published public private(set) var phase: CapturePhase = .idle
    /// The meters, silent unless recording.
    @Published public private(set) var levels: CaptureLevels = .silent
    /// Inputs the running capture sees, empty when idle.
    @Published public private(set) var microphones = MicrophoneList()
    /// The microphone the running capture records.
    @Published public private(set) var microphone: MicrophoneDevice?
    /// The microphone the system proposed, until the user answers or a newer change replaces it.
    @Published public private(set) var offer: MicrophoneOffer?
    /// A microphone change is in progress.
    @Published public private(set) var isSwitchingMicrophone = false
    /// Called for every capture that ended, whatever ended it, before the transcription is requested.
    public var onEnd: ((CaptureEnding) -> Void)?
    /// Called when the microphone in use disappeared and another took over, with the lost one and
    /// its replacement, after the user was told through the notifier.
    public var onForcedSwitch: ((MicrophoneDevice, MicrophoneDevice) -> Void)?

    private let notifier: any UserNotifier
    private let transcribe: @MainActor (UUID) async -> WorkDecision
    private let now: @MainActor () -> TimeInterval
    private let date: @MainActor () -> Date
    private let settings: @MainActor () -> SettingsStore?
    private var capture: (any AudioCapture)?
    private var library: SessionLibrary?
    private var listener: Task<Void, Never>?
    private var clock = SessionClock()
    /// When the clock froze for a restart of the microphone stream.
    private var restartFrozenAt: TimeInterval?

    /// - Parameters:
    ///   - transcribe: requests a session's transcription; the decision says whether it starts or waits.
    ///   - now: a monotonic time in seconds.
    ///   - date: the wall-clock time, recorded when a capture resumes or stops.
    ///   - settings: where the last microphone chosen is remembered.
    public init(notifier: any UserNotifier, transcribe: @escaping @MainActor (UUID) async -> WorkDecision,
                now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                date: @escaping @MainActor () -> Date = { Date() },
                settings: @escaping @MainActor () -> SettingsStore? = { nil }) {
        self.notifier = notifier; self.transcribe = transcribe; self.now = now; self.date = date; self.settings = settings
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
        do { try await capture.start(session: id, continuing: .start, microphone: request.microphone) } catch { phase = .idle; throw error }
        if let chosen = request.microphone { remember(chosen) }
        var item = Recording(id: id, title: title, kind: request.sessionKind, state: .recording, isDemo: capture.isSimulated)
        item.microphone = await capture.microphone?.name
        if !capture.isSimulated { item.calendarContext = request.meeting; item.speechLanguage = request.language ?? SpeechLanguage.automatic }
        library.insert(item)
        await begin(id, capture: capture, in: library, at: 0)
        return id
    }

    /// Resumes recording in `id`, a session that ended, whether stopped or interrupted. The new
    /// chunks follow the earlier audio on the session's timeline and are numbered after its files;
    /// the clock starts at the session's recorded time, so new notes follow the earlier ones. The
    /// session records a `resumed` boundary (`Recording.boundaries`) with the microphone the capture
    /// names; title, kind, calendar and language stay.
    ///
    /// Returns false when a capture already runs or starts. Throws `ResumeRefusal` when the session
    /// cannot be resumed (`SessionResume.refusal`; work on the session is the caller's to check),
    /// or the capture's error when it cannot start: the session is unchanged then. `microphone` is
    /// the input to record, nil for the system default input.
    @discardableResult
    public func continueRecording(_ id: UUID, with capture: any AudioCapture, in library: SessionLibrary, microphone: String? = nil) async throws -> Bool {
        guard phase == .idle else { return false }
        guard let item = library.recording(id) else { throw StoreError.notFound }
        // A simulation never records into a session: its audio does not exist.
        if capture.isSimulated { throw ResumeRefusal.example }
        if let refusal = SessionResume.refusal(for: item, now: date(), captureIdle: true) { throw refusal }
        phase = .starting
        let continuation = CaptureContinuation(after: item)
        do { try await capture.start(session: id, continuing: continuation, microphone: microphone) } catch { phase = .idle; throw error }
        // Deleted while the devices started: nothing to record into.
        guard library.recording(id) != nil else {
            _ = await capture.stop(); phase = .idle
            throw StoreError.notFound
        }
        let device = await capture.microphone
        let boundary = CaptureBoundary(offset: continuation.offset, at: date(), reason: .resumed, microphone: device?.name)
        library.edit(id) {
            $0.state = .recording; $0.boundaries = ($0.boundaries ?? []) + [boundary]
            if $0.microphone == nil { $0.microphone = device?.name }
        }
        await begin(id, capture: capture, in: library, at: continuation.offset)
        return true
    }

    /// The capture of `id` runs: the clock starts at `offset`, events are heard, the session is saved.
    private func begin(_ id: UUID, capture: any AudioCapture, in library: SessionLibrary, at offset: TimeInterval) async {
        self.capture = capture; self.library = library
        clock = SessionClock(); clock.shift(by: offset); clock.run(at: now()); restartFrozenAt = nil
        microphone = await capture.microphone; microphones = await capture.microphones; offer = nil
        phase = .recording(id)
        let events = capture.events
        listener = Task { [weak self] in
            for await event in events { self?.handle(event, session: id) }
        }
        if !capture.isSimulated { await library.flush() }
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
        // A restart that began before the pause ended with it (`AudioCapture.pause`).
        restartFrozenAt = nil
        clock.run(at: now())
        phase = .recording(id)
    }

    /// Ends the capture: the session is sealed, or interrupted after a fault, with the audio
    /// recorded so far added to what it held, and the time it ended. Then its transcription is
    /// requested, unless it holds no audio or is a simulation. Returns nil when no capture runs or
    /// it is already stopping.
    @discardableResult
    public func stop(_ cause: CaptureStop = .requested) async -> CaptureEnding? {
        guard let id = phase.sessionID, phase != .stopping(id), let capture, let library else { return nil }
        let duration = elapsed
        clock.freeze(at: now())
        phase = .stopping(id); levels = .silent
        listener?.cancel(); listener = nil
        let audio = await capture.stop()
        self.capture = nil; self.library = nil
        resetMicrophones()
        let interrupted = audio.finalizationError != nil || { if case .failed = cause { true } else { false } }()
        let endedAt = date()
        library.edit(id) {
            $0.duration = duration; $0.state = interrupted ? .interrupted : .sealed; $0.endedAt = endedAt
            // A resumed session keeps its earlier audio.
            $0.audioChunks += audio.chunks
        }
        let hasAudio = !(library.recording(id)?.audioChunks ?? audio.chunks).isEmpty
        phase = .idle
        clock = SessionClock()
        if let error = audio.finalizationError { notifier.notify(.error(error)) }
        if capture.isSimulated { notifier.notify(.info(String(localized: "Simulation terminée. Les notes restent disponibles.", bundle: .hwyd))) }
        else if audio.chunks.isEmpty { notifier.notify(.info(String(localized: "Aucun audio reçu. Vos notes sont conservées.", bundle: .hwyd))) }
        if case .failed(let fault) = cause { notifier.notify(.error(fault.message)) }
        let ending = CaptureEnding(sessionID: id, cause: cause, finalizationError: audio.finalizationError)
        onEnd?(ending)
        // A resumed session is transcribed again as a whole, even when this capture received nothing.
        if !capture.isSimulated, hasAudio {
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
        resetMicrophones()
        _ = await capture.stop()
    }

    // MARK: Microphone

    /// Records `uid` from now on, the user's choice; the choice is remembered. A failure is
    /// reported and the capture keeps its microphone.
    public func chooseMicrophone(_ uid: String) async {
        guard isRunning, uid != microphone?.uid else { return }
        remember(uid)
        if offer?.device.uid == uid { offer = nil }
        await switchMicrophone(to: uid, reason: .user)
    }

    /// Switches to the microphone the system proposed; it becomes the remembered choice.
    public func acceptOffer() async {
        guard let offer, isRunning else { return }
        self.offer = nil
        remember(offer.device.uid)
        await switchMicrophone(to: offer.device.uid, reason: .accepted)
    }

    /// Keeps the microphone in use; the offer goes away.
    public func declineOffer() { offer = nil }

    private func switchMicrophone(to uid: String, reason: MicrophoneSwitchReason) async {
        guard let capture, !isSwitchingMicrophone else { return }
        isSwitchingMicrophone = true
        defer { isSwitchingMicrophone = false }
        do { try await capture.switchMicrophone(to: uid, reason: reason) }
        catch { if phase.sessionID != nil { notifier.notify(.error(error.localizedDescription)) } }
    }

    /// The microphone in use disappeared: the system default input takes over and the user is told,
    /// or the session is interrupted, audio kept, when no input is left.
    private func replace(_ lost: MicrophoneDevice, session id: UUID) async {
        guard let capture, phase.sessionID == id else { return }
        let list = await capture.microphones
        microphones = list
        if offer?.device.uid == lost.uid { offer = nil }
        guard let next = list.replacement(for: lost.uid) else {
            await stop(.failed(CaptureFault(.noMicrophone, message: String(localized: "Le micro \(lost.name) n’est plus disponible et aucun autre micro n’est branché. La session est interrompue, l’audio est conservé. Reprenez-la une fois un micro branché.", bundle: .hwyd))))
            return
        }
        isSwitchingMicrophone = true
        defer { isSwitchingMicrophone = false }
        do {
            try await capture.switchMicrophone(to: next.uid, reason: .forced)
            guard phase.sessionID == id else { return }
            notifier.notify(.info(String(localized: "Le micro \(lost.name) n’est plus disponible. L’enregistrement continue sur \(next.name).", bundle: .hwyd)))
            onForcedSwitch?(lost, next)
        } catch {
            // The capture reported its fault too; the first one stops the session.
            await stop(.failed(CaptureFault(.restart, message: error.localizedDescription)))
        }
    }

    /// Recording or paused: the capture can change microphone.
    private var isRunning: Bool { switch phase { case .recording, .paused: true; default: false } }

    private func remember(_ uid: String) { settings()?.set(uid, for: .microphone) }

    private func resetMicrophones() { microphones = MicrophoneList(); microphone = nil; offer = nil }

    /// Records where the new microphone starts on the session's timeline. The clock stands still
    /// while the graph is rebuilt, so its time is where the audio resumes.
    private func recordSwitch(to device: MicrophoneDevice, reason: MicrophoneSwitchReason, session id: UUID) {
        microphone = device
        if offer?.device.uid == device.uid { offer = nil }
        let boundary = CaptureBoundary(offset: elapsed, at: date(), reason: reason.boundary, microphone: device.name)
        library?.edit(id) { $0.boundaries = ($0.boundaries ?? []) + [boundary] }
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
        case .microphonesChanged(let list):
            microphones = list
            // An offer the system took back, or whose device went away, is moot.
            if let offer, list.device(offer.device.uid) == nil || list.defaultInput == microphone?.uid { self.offer = nil }
        case .microphoneOffered(let device):
            guard device.uid != microphone?.uid else { return }
            // A newer change replaces the pending offer.
            offer = MicrophoneOffer(device: device, current: microphone?.name)
        case .microphoneLost(let device):
            Task { await replace(device, session: id) }
        case .microphoneSwitched(let device, let reason):
            recordSwitch(to: device, reason: reason, session: id)
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
