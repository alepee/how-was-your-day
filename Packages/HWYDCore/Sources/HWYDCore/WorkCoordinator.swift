import Foundation

/// Whether a kind of work can start now. A service states its own conditions with `unavailable`;
/// the coordinator adds `busy` when other heavy work runs or waits. `Never` means the work has
/// no condition of its own.
public enum Availability<Unavailability: Equatable & Sendable>: Equatable, Sendable {
    case ready
    /// Another job runs or waits; this one would wait its turn.
    case busy(WorkBusy)
    case unavailable(Unavailability)

    public var isReady: Bool { if case .ready = self { true } else { false } }
    /// The work can be asked for: it starts now or waits its turn. Only the service's own
    /// conditions keep it from being asked.
    public var canRequest: Bool { if case .unavailable = self { false } else { true } }

    /// The service's own conditions come first: a service that cannot run says why even while
    /// other work is busy. A ready service takes the coordinator's state.
    public func combined(with work: Availability<Never>) -> Self {
        guard case .ready = self, case .busy(let busy) = work else { return self }
        return .busy(busy)
    }
}

extension Availability where Unavailability: LocalizedError {
    /// The reason to show, nil when ready.
    public var reason: String? {
        switch self {
        case .ready: nil
        case .busy(let busy): busy.localizedDescription
        case .unavailable(let reason): reason.localizedDescription
        }
    }
}

/// What a voice print job changes for one person. These jobs are quick writes that erase or
/// unblock: they run on their own lane, beside the heavy work.
public enum VoicePrintChange: Hashable, Sendable {
    case forget
    case oppose
    /// What one session added to the print (nil: samples of unknown origin).
    case withdraw(session: UUID?)
    case liftOpposition
}

/// One piece of work. Heavy jobs run one at a time: they share the CPU, the Neural Engine and,
/// for summaries, the transcript they read. Voice print changes run on a lane of their own, so an
/// erasure or an opposition never waits for a transcription.
public enum WorkJob: Hashable, Sendable {
    case transcription(session: UUID)
    case summary(session: UUID)
    /// Recognition of a session's voices, or a voice memory job with no session (nil).
    case voice(session: UUID?)
    /// Memorizing a voice of `session` as `person`.
    case enrollment(session: UUID, person: UUID)
    case speechModel(locale: String)
    case diarizer
    /// A change to one person's voice print.
    case voicePrint(person: UUID, change: VoicePrintChange)

    public enum Kind: Hashable, Sendable { case transcription, summary, voice, modelInstall, voicePrint }
    /// Jobs on different lanes run side by side; jobs on one lane run one at a time.
    public enum Lane: Hashable, Sendable, CaseIterable { case heavy, voicePrints }

    public var kind: Kind {
        switch self {
        case .transcription: .transcription
        case .summary: .summary
        case .voice, .enrollment: .voice
        case .speechModel, .diarizer: .modelInstall
        case .voicePrint: .voicePrint
        }
    }

    public var lane: Lane { kind == .voicePrint ? .voicePrints : .heavy }

    /// The session the job reads or writes, if any. A voice print change names the session it
    /// withdraws from, but reads and writes no session.
    public var sessionID: UUID? {
        switch self {
        case .transcription(let id), .summary(let id): id
        case .voice(let id): id
        case .enrollment(let id, _): id
        case .speechModel, .diarizer, .voicePrint: nil
        }
    }

    /// The person whose print the job writes, if any.
    public var personID: UUID? {
        switch self {
        case .enrollment(_, let person), .voicePrint(let person, _): person
        default: nil
        }
    }

    /// Two jobs on different lanes that must not run at the same time: a voice print change and a
    /// voice job, which both read or write prints. The helper's print lock covers the short
    /// recognition step of a transcription.
    public func conflicts(with other: WorkJob) -> Bool {
        lane != other.lane && Set([kind, other.kind]) == [.voice, .voicePrint]
    }
}

/// The job that keeps other work from starting.
public struct WorkBusy: LocalizedError, Hashable, Sendable {
    public let job: WorkJob
    public init(job: WorkJob) { self.job = job }

    public var errorDescription: String? {
        switch job.kind {
        case .transcription: String(localized: "Une transcription est en cours.", bundle: .hwyd)
        case .summary: String(localized: "Une synthèse est en cours.", bundle: .hwyd)
        case .voice: String(localized: "Un traitement des voix est en cours.", bundle: .hwyd)
        case .modelInstall: String(localized: "Une installation de modèle est en cours.", bundle: .hwyd)
        case .voicePrint: String(localized: "Une modification d’empreinte vocale est en cours.", bundle: .hwyd)
        }
    }
}

/// Why a request was not taken.
public enum WorkRefusal: LocalizedError, Equatable, Sendable {
    /// The same job already runs or waits.
    case alreadyRequested(WorkJob)
    /// The service or the session cannot run this job; the reason is already localized.
    case unavailable(String)
    /// The examples run no processing: their services stand in for the real ones.
    case examples
    /// The session holds no audio to process.
    case noAudio
    /// The session is not in the library.
    case sessionNotFound
    /// The local store could not be opened.
    case storeUnavailable
    /// Work runs or waits on the session, so it cannot be deleted.
    case sessionInUse

    public var errorDescription: String? {
        switch self {
        case .alreadyRequested: String(localized: "Ce traitement est déjà en cours ou en attente.", bundle: .hwyd)
        case .unavailable(let reason): reason
        case .examples: String(localized: "Les exemples ne lancent aucun traitement.", bundle: .hwyd)
        case .noAudio: String(localized: "Aucun fichier audio disponible pour cette session.", bundle: .hwyd)
        case .sessionNotFound: String(localized: "Session introuvable sur ce Mac.", bundle: .hwyd)
        case .storeUnavailable: String(localized: "Le store local n’est pas disponible.", bundle: .hwyd)
        case .sessionInUse: String(localized: "Cette session est en cours de traitement. Annulez le traitement ou attendez sa fin pour la supprimer.", bundle: .hwyd)
        }
    }
}

/// What happened to a request.
public enum WorkDecision: Equatable, Sendable {
    /// The job started.
    case accepted
    /// The job waits behind the one that runs, and starts when the work before it ends.
    case queued(behind: WorkBusy)
    case refused(WorkRefusal)
}

/// The coordinator's state at one moment. `revision` grows with every change, so an observer
/// can drop a snapshot older than the one it shows.
public struct WorkSnapshot: Equatable, Sendable {
    /// The heavy job that runs.
    public var running: WorkJob?
    /// The voice print change that runs, beside the heavy job.
    public var runningVoicePrint: WorkJob?
    /// Jobs waiting, in the order they were asked; each lane starts its own in that order.
    public var queued: [WorkJob]
    public var revision: Int

    public init(running: WorkJob? = nil, runningVoicePrint: WorkJob? = nil, queued: [WorkJob] = [], revision: Int = 0) {
        self.running = running; self.runningVoicePrint = runningVoicePrint; self.queued = queued; self.revision = revision
    }

    /// Some work runs or waits.
    public var isBusy: Bool { running != nil || runningVoicePrint != nil || !queued.isEmpty }
    /// Busy with the running heavy job, or with the first waiting one between two jobs. A new
    /// heavy job would wait behind it.
    public var availability: Availability<Never> {
        (running ?? queued.first { $0.lane == .heavy }).map { .busy(WorkBusy(job: $0)) } ?? .ready
    }
    public func isRunning(_ job: WorkJob) -> Bool { running == job || runningVoicePrint == job }
    public func isQueued(_ job: WorkJob) -> Bool { queued.contains(job) }
    /// Jobs that run or wait on this session.
    public func jobs(for session: UUID) -> [WorkJob] {
        ([running, runningVoicePrint].compactMap { $0 } + queued).filter { $0.sessionID == session }
    }
}

/// Owns work exclusivity. Heavy jobs (transcription, voice recognition and enrollment, model
/// installs, summaries) run one at a time, in the order asked; voice print changes run one at a
/// time on their own lane, beside them, but never with a voice job. Every request runs or waits:
/// callers request a job and get a decision; they never check a busy flag first.
///
/// `hwyd-pipeline` keeps its own `flock` on the store, for a second process (another app instance,
/// a script) that this coordinator cannot see, and a short lock around the voice prints.
public actor WorkCoordinator {
    private struct Entry {
        let job: WorkJob
        let run: @Sendable () async -> Void
    }
    private struct Running {
        let job: WorkJob
        let token: UUID
        let task: Task<Void, Never>
        /// The job was cancelled: it ends on its own, and the same job asked again waits for it.
        var cancelled = false
    }
    private var running: [WorkJob.Lane: Running] = [:]
    private var queue: [Entry] = []
    private var revision = 0
    private var observers: [UUID: AsyncStream<WorkSnapshot>.Continuation] = [:]
    private var busyObservers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var lastBusy = false

    public init() {}

    public var snapshot: WorkSnapshot {
        WorkSnapshot(running: running[.heavy]?.job, runningVoicePrint: running[.voicePrints]?.job, queued: queue.map(\.job), revision: revision)
    }

    /// Starts `run` now if its lane is free and nothing conflicting runs, or queues it behind the
    /// work before it. A cancelled job sees `Task.isCancelled`; it still runs to its end, cleanup
    /// included, before the next one of its lane starts. The same job asked again while a
    /// cancelled run ends is queued behind it.
    @discardableResult
    public func request(_ job: WorkJob, run: @escaping @Sendable () async -> Void) -> WorkDecision {
        let current = running[job.lane]
        if queue.contains(where: { $0.job == job }) || (current?.job == job && current?.cancelled == false) { return .refused(.alreadyRequested(job)) }
        if let blocker = blocker(of: job) {
            queue.append(Entry(job: job, run: run)); changed()
            return .queued(behind: WorkBusy(job: blocker))
        }
        start(Entry(job: job, run: run)); changed()
        return .accepted
    }

    /// Cancels the jobs that match: a running one is asked to stop, waiting ones are dropped.
    /// Returns the jobs it cancelled, running ones included.
    @discardableResult
    public func cancel(where matches: @Sendable (WorkJob) -> Bool) -> [WorkJob] {
        var cancelled = queue.map(\.job).filter(matches)
        let before = queue.count
        queue.removeAll { matches($0.job) }
        for lane in WorkJob.Lane.allCases {
            guard var current = running[lane], !current.cancelled, matches(current.job) else { continue }
            current.task.cancel(); current.cancelled = true; running[lane] = current
            cancelled.insert(current.job, at: 0)
        }
        if queue.count != before { changed() }
        return cancelled
    }

    @discardableResult
    public func cancel(_ job: WorkJob) -> [WorkJob] { cancel { $0 == job } }

    /// Drops the waiting jobs that match; the running ones go on.
    public func dropQueued(where matches: @Sendable (WorkJob) -> Bool) {
        let before = queue.count
        queue.removeAll { matches($0.job) }
        if queue.count != before { startWaiting(); changed() }
    }
    public func cancelAll() { cancel { _ in true } }

    /// Callers of `idle()` waiting for the work to end, for tests.
    var idleWaiterCount: Int { idleWaiters.count }

    /// Returns once nothing runs or waits. Returns early if the calling task is cancelled.
    public func idle() async {
        guard snapshot.isBusy else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || !snapshot.isBusy { continuation.resume() } else { idleWaiters[id] = continuation }
            }
        } onCancel: {
            Task { await self.releaseIdleWaiter(id) }
        }
    }

    /// Every change, starting with the current state.
    public func snapshots() -> AsyncStream<WorkSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: WorkSnapshot.self, bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        return stream
    }

    /// Whether some work runs or waits, starting with the current value, then each time it flips.
    public func busyChanges() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        busyObservers[id] = continuation
        continuation.yield(snapshot.isBusy)
        continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        return stream
    }

    /// What keeps `job` from starting now, if anything: the job running on its lane, a job of
    /// its lane asked before it, a conflicting job running on the other lane, or, for a voice job,
    /// a voice print change waiting for its turn, which goes first.
    private func blocker(of job: WorkJob) -> WorkJob? {
        running[job.lane]?.job
            ?? queue.first { $0.job.lane == job.lane }?.job
            ?? running.values.first { $0.job.conflicts(with: job) }?.job
            ?? (job.lane == .heavy ? queue.first { $0.job.conflicts(with: job) }?.job : nil)
    }

    private func start(_ entry: Entry) {
        let token = UUID()
        let run = entry.run
        let task = Task { [weak self] in
            await run()
            await self?.finished(entry.job.lane, token)
        }
        running[entry.job.lane] = Running(job: entry.job, token: token, task: task)
    }

    /// Starts, on each free lane, the first job of that lane that nothing conflicting holds back.
    /// Voice print changes start first: a voice job waiting beside one waits for it.
    private func startWaiting() {
        for lane in [WorkJob.Lane.voicePrints, .heavy] where running[lane] == nil {
            guard let index = queue.firstIndex(where: { $0.job.lane == lane }),
                  !running.values.contains(where: { $0.job.conflicts(with: queue[index].job) }) else { continue }
            start(queue.remove(at: index))
        }
    }

    private func finished(_ lane: WorkJob.Lane, _ token: UUID) {
        guard running[lane]?.token == token else { return }
        running[lane] = nil
        startWaiting()
        changed()
    }

    private func changed() {
        revision += 1
        let current = snapshot
        for observer in observers.values { observer.yield(current) }
        if current.isBusy != lastBusy {
            lastBusy = current.isBusy
            for observer in busyObservers.values { observer.yield(current.isBusy) }
        }
        if !current.isBusy {
            let waiters = idleWaiters.values
            idleWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    private func releaseIdleWaiter(_ id: UUID) { idleWaiters.removeValue(forKey: id)?.resume() }
    private func removeObserver(_ id: UUID) { observers[id] = nil; busyObservers[id] = nil }
}
