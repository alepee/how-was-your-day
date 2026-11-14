import Foundation

/// Whether a kind of work can start now. A service states its own conditions with `unavailable`;
/// the coordinator adds `busy` when other heavy work runs or waits. `Never` means the work has
/// no condition of its own.
public enum Availability<Unavailability: Equatable & Sendable>: Equatable, Sendable {
    case ready
    /// Another job runs or waits; this one would be refused or queued.
    case busy(WorkBusy)
    case unavailable(Unavailability)

    public var isReady: Bool { if case .ready = self { true } else { false } }

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

/// One piece of heavy work. Only one runs at a time: they share the CPU, the Neural Engine,
/// the helper's lock and, for summaries, the transcript they read.
public enum WorkJob: Hashable, Sendable {
    case transcription(session: UUID)
    case summary(session: UUID)
    /// A voice memory job, about one session (enrollment, recognition) or about people only (nil).
    case voice(session: UUID?)
    case speechModel(locale: String)
    case diarizer

    public enum Kind: Hashable, Sendable { case transcription, summary, voice, modelInstall }

    public var kind: Kind {
        switch self {
        case .transcription: .transcription
        case .summary: .summary
        case .voice: .voice
        case .speechModel, .diarizer: .modelInstall
        }
    }

    /// The session the job reads or writes, if any.
    public var sessionID: UUID? {
        switch self {
        case .transcription(let id), .summary(let id): id
        case .voice(let id): id
        case .speechModel, .diarizer: nil
        }
    }

    /// A transcription asked while other work runs waits its turn: the end of a capture must not
    /// lose it. Other jobs are started by the user, who sees the refusal and its reason.
    public var waitsWhenBusy: Bool { kind == .transcription }
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
        }
    }
}

/// Why a request was not taken.
public enum WorkRefusal: LocalizedError, Equatable, Sendable {
    /// Other work runs and this kind of job does not wait.
    case busy(WorkBusy)
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

    public var errorDescription: String? {
        switch self {
        case .busy(let busy): (busy.errorDescription ?? "") + " " + String(localized: "Réessayez une fois ce traitement terminé.", bundle: .hwyd)
        case .alreadyRequested: String(localized: "Ce traitement est déjà en cours ou en attente.", bundle: .hwyd)
        case .unavailable(let reason): reason
        case .examples: String(localized: "Les exemples ne lancent aucun traitement.", bundle: .hwyd)
        case .noAudio: String(localized: "Aucun fichier audio disponible pour cette session.", bundle: .hwyd)
        case .sessionNotFound: String(localized: "Session introuvable sur ce Mac.", bundle: .hwyd)
        case .storeUnavailable: String(localized: "Le store local n’est pas disponible.", bundle: .hwyd)
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
    public var running: WorkJob?
    /// Jobs waiting, in the order they will start.
    public var queued: [WorkJob]
    public var revision: Int

    public init(running: WorkJob? = nil, queued: [WorkJob] = [], revision: Int = 0) {
        self.running = running; self.queued = queued; self.revision = revision
    }

    /// Some work runs or waits.
    public var isBusy: Bool { running != nil || !queued.isEmpty }
    /// Busy with the running job, or with the first waiting one between two jobs.
    public var availability: Availability<Never> {
        (running ?? queued.first).map { .busy(WorkBusy(job: $0)) } ?? .ready
    }
    public func isRunning(_ job: WorkJob) -> Bool { running == job }
    public func isQueued(_ job: WorkJob) -> Bool { queued.contains(job) }
    /// Jobs that run or wait on this session.
    public func jobs(for session: UUID) -> [WorkJob] {
        ([running].compactMap { $0 } + queued).filter { $0.sessionID == session }
    }
}

/// Owns heavy-work exclusivity: transcription, voice jobs, model installs and summaries run one at
/// a time. Callers request a job and get a decision; they never check a busy flag first.
///
/// `hwyd-pipeline` keeps its own `flock` on the store, for a second process (another app instance,
/// a script) that this coordinator cannot see.
public actor WorkCoordinator {
    private struct Entry {
        let job: WorkJob
        let run: @Sendable () async -> Void
    }
    private var running: (job: WorkJob, token: UUID, task: Task<Void, Never>)?
    private var queue: [Entry] = []
    private var revision = 0
    private var observers: [UUID: AsyncStream<WorkSnapshot>.Continuation] = [:]
    private var busyObservers: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var lastBusy = false

    public init() {}

    public var snapshot: WorkSnapshot {
        WorkSnapshot(running: running?.job, queued: queue.map(\.job), revision: revision)
    }

    /// Starts `run` now if nothing else runs, queues it if its kind waits, or refuses it. A
    /// cancelled job sees `Task.isCancelled`; it still runs to its end, cleanup included, before
    /// the next one starts.
    @discardableResult
    public func request(_ job: WorkJob, run: @escaping @Sendable () async -> Void) -> WorkDecision {
        if running?.job == job || queue.contains(where: { $0.job == job }) { return .refused(.alreadyRequested(job)) }
        guard let current = running?.job else {
            start(Entry(job: job, run: run)); changed()
            return .accepted
        }
        guard job.waitsWhenBusy else { return .refused(.busy(WorkBusy(job: current))) }
        queue.append(Entry(job: job, run: run)); changed()
        return .queued(behind: WorkBusy(job: current))
    }

    /// Cancels the jobs that match: a running one is asked to stop, waiting ones are dropped.
    public func cancel(where matches: @Sendable (WorkJob) -> Bool) {
        let before = queue.count
        queue.removeAll { matches($0.job) }
        if let running, matches(running.job) { running.task.cancel() }
        if queue.count != before { changed() }
    }

    public func cancel(_ job: WorkJob) { cancel { $0 == job } }
    public func cancelAll() { cancel { _ in true } }

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

    private func start(_ entry: Entry) {
        let token = UUID()
        let run = entry.run
        let task = Task { [weak self] in
            await run()
            await self?.finished(token)
        }
        running = (entry.job, token, task)
    }

    private func finished(_ token: UUID) {
        guard running?.token == token else { return }
        running = nil
        if !queue.isEmpty { start(queue.removeFirst()) }
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
