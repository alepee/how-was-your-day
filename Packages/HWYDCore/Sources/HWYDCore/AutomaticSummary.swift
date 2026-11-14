import Foundation

/// Starts a session's summary on its own once the session is ready, when the user turned it on.
///
/// It looks only at the session: ready for a summary (`Recording.isReadyForSummary`), ended after
/// the setting was turned on (a meeting recorded at that moment counts), and unchanged for `delay`, so the « Annuler » offered after a
/// correction stays usable. It then requests the summary; whether one can run (provider, key, model,
/// agent, other work) is the summarizer's and the work coordinator's answer, not this trigger's.
///
/// One request per transcript version: a failed or cancelled run is not requested again until the
/// transcript changes. Once a session has a summary it is never requested again, even when a later
/// correction makes it stale; regenerating it is the user's decision.
@MainActor public final class AutomaticSummaryTrigger {
    /// Sessions that end from this date are summarized on their own; nil while the setting is off.
    public var enabledSince: Date? {
        didSet { if enabledSince != oldValue { sessionsChanged() } }
    }
    private let delay: Duration
    /// Waits `delay`; tests replace it with a clock they advance themselves.
    private let sleep: @MainActor @Sendable (Duration) async throws -> Void
    private let sessions: () -> [Recording]
    private let request: (UUID) -> Void
    /// Sessions waiting for their delay, with the revision the wait started from.
    private var waiting: [UUID: (revision: Int, task: Task<Void, Never>)] = [:]
    /// Transcript version of the last request, per session.
    private var requested: [UUID: Int] = [:]

    public init(delay: Duration = .seconds(10), enabledSince: Date?, sessions: @escaping () -> [Recording],
                request: @escaping (UUID) -> Void,
                sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.delay = delay; self.enabledSince = enabledSince; self.sessions = sessions; self.request = request; self.sleep = sleep
    }

    /// Sessions waiting for their delay, for tests.
    public var waitingSessions: Set<UUID> { Set(waiting.keys) }
    /// Sessions already requested at their current transcript version, for tests.
    var requestedSessions: Set<UUID> { Set(requested.keys) }

    /// Looks at the sessions again after a change, here or in another process. A session that
    /// changed waits `delay` again.
    public func sessionsChanged() {
        let current = sessions()
        let known = Set(current.map(\.id))
        for id in waiting.keys where !known.contains(id) { stopWaiting(id) }
        requested = requested.filter { known.contains($0.key) }
        for item in current { consider(item) }
    }

    /// Takes the sessions as they are now as already considered. Called once the library is loaded:
    /// a session left waiting or refused before the app quit is requested again only after its
    /// transcript changes, as the work queue is not resumed at launch either.
    public func adoptCurrentSessions() {
        for item in sessions() where eligible(item) {
            requested[item.id] = item.transcriptVersion
            stopWaiting(item.id)
        }
    }

    /// The requested run read a session that changed before its result was saved: it may be
    /// requested again once the session is ready and quiet.
    public func runWasStale(_ id: UUID) {
        requested[id] = nil
        sessionsChanged()
    }

    private func eligible(_ item: Recording) -> Bool {
        guard let since = enabledSince else { return false }
        let ended = item.startedAt.addingTimeInterval(item.duration)
        return ended >= since && item.isReadyForSummary && requested[item.id] != item.transcriptVersion
    }

    private func consider(_ item: Recording) {
        guard eligible(item) else { stopWaiting(item.id); return }
        if waiting[item.id]?.revision == item.revision { return }
        stopWaiting(item.id)
        let id = item.id, revision = item.revision, delay = delay, sleep = sleep
        let task = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled else { return }
            self?.fire(id, revision: revision)
        }
        waiting[id] = (revision, task)
    }

    private func fire(_ id: UUID, revision: Int) {
        guard waiting[id]?.revision == revision else { return }
        waiting[id] = nil
        guard let item = sessions().first(where: { $0.id == id }), item.revision == revision, eligible(item) else { return }
        requested[id] = item.transcriptVersion
        request(id)
    }

    private func stopWaiting(_ id: UUID) { waiting.removeValue(forKey: id)?.task.cancel() }
}
