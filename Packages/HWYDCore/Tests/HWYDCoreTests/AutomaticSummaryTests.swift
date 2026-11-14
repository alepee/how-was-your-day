import XCTest
@testable import HWYDCore

/// A clock the test advances: each wait of the trigger suspends until the test ends it.
@MainActor private final class ManualClock {
    private var waits: [CheckedContinuation<Void, Never>] = []
    var pending: Int { waits.count }
    func sleep() async { await withCheckedContinuation { waits.append($0) } }
    /// Ends the oldest `count` waits (all when nil), then lets the trigger act on them.
    func advance(_ count: Int? = nil) async {
        await settle()
        let ended = waits.prefix(count ?? waits.count)
        waits.removeFirst(ended.count)
        ended.forEach { $0.resume() }
        await settle()
    }
    /// Lets the tasks already started on the main actor run.
    func settle() async { for _ in 0..<50 { await Task.yield() } }
}

@MainActor
final class AutomaticSummaryTests: XCTestCase {
    private var sessions: [Recording] = []
    private var requests: [UUID] = []
    private let clock = ManualClock()

    override func tearDown() async throws {
        await clock.advance() // No wait is left suspended.
        try await super.tearDown()
    }

    private func trigger(since: Date? = .distantPast) -> AutomaticSummaryTrigger {
        AutomaticSummaryTrigger(enabledSince: since, sessions: { [unowned self] in sessions },
                                request: { [unowned self] in requests.append($0) },
                                sleep: { [clock] _ in await clock.sleep() })
    }
    private func ready(startedAt: Date = Date(), duration: Double = 0) -> Recording {
        let voice = Speaker(label: "Alice", confirmed: true)
        return Recording(title: "Atelier", startedAt: startedAt, duration: duration, speakers: [voice],
                         segments: [.init(start: 0, end: 1, speakerID: voice.id, source: .mic, text: "Bonjour")])
    }
    /// The delay ends for every session waiting.
    private func settle() async { await clock.advance() }
    /// A commit, as the library reports it: the next revision.
    private func commit(_ index: Int, _ edit: (inout Recording) throws -> Void) rethrows {
        try edit(&sessions[index]); sessions[index].revision += 1
    }

    func testRequestsOnceTheSessionIsReadyAndQuiet() async throws {
        let voice = Speaker(label: "Voix 1")
        sessions = [Recording(title: "Atelier", speakers: [voice], segments: [.init(start: 0, end: 1, speakerID: voice.id, source: .mic, text: "Bonjour")])]
        let trigger = trigger()
        trigger.sessionsChanged()
        await settle()
        XCTAssertTrue(requests.isEmpty, "An unnamed voice keeps the session from being ready")
        try commit(0) { try $0.renameSpeaker(voice.id, to: "Alice") }
        trigger.sessionsChanged()
        XCTAssertEqual(trigger.waitingSessions, [sessions[0].id])
        await settle()
        XCTAssertEqual(requests, [sessions[0].id])
    }

    func testAChangeDuringTheDelayStartsItAgain() async throws {
        sessions = [ready()]
        let trigger = trigger()
        trigger.sessionsChanged()
        await clock.settle()
        commit(0) { $0.notes = "Une note" }
        trigger.sessionsChanged()
        await clock.advance(1)
        XCTAssertTrue(requests.isEmpty, "The delay counts from the last change")
        XCTAssertEqual(trigger.waitingSessions, [sessions[0].id])
        await clock.advance()
        XCTAssertEqual(requests.count, 1)
    }

    func testASessionDeletedWhileWaitingIsNotRequested() async throws {
        sessions = [ready(), ready()]
        let trigger = trigger()
        trigger.sessionsChanged()
        XCTAssertEqual(trigger.waitingSessions.count, 2)
        let kept = sessions[1].id
        sessions.removeFirst()
        trigger.sessionsChanged()
        XCTAssertEqual(trigger.waitingSessions, [kept], "A deleted session stops waiting")
        // Deleted once more, without a change reported before the delay ends.
        sessions = []
        await settle()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(trigger.waitingSessions.isEmpty)
    }

    func testADeletedSessionIsForgotten() async throws {
        sessions = [ready()]
        let trigger = trigger()
        trigger.sessionsChanged(); await settle()
        XCTAssertEqual(trigger.requestedSessions, [sessions[0].id])
        sessions = []
        trigger.sessionsChanged()
        XCTAssertTrue(trigger.requestedSessions.isEmpty)
    }

    func testOneRequestPerTranscriptVersionAndNoteEditsDoNotRestartIt() async throws {
        sessions = [ready()]
        let trigger = trigger()
        trigger.sessionsChanged(); await settle()
        XCTAssertEqual(requests.count, 1)
        // The run failed or was cancelled: no summary. A note edit does not request it again.
        commit(0) { $0.notes = "Une note" }
        trigger.sessionsChanged(); await settle()
        XCTAssertEqual(requests.count, 1)
        // A transcript correction does.
        try commit(0) { try $0.renameSpeaker($0.speakers[0].id, to: "Alice B.") }
        trigger.sessionsChanged(); await settle()
        XCTAssertEqual(requests.count, 2)
    }

    func testSessionsFoundAtLaunchWaitForANewTranscript() async throws {
        sessions = [ready()]
        let trigger = trigger()
        trigger.sessionsChanged()
        trigger.adoptCurrentSessions()
        XCTAssertTrue(trigger.waitingSessions.isEmpty)
        await settle()
        XCTAssertTrue(requests.isEmpty)
        try commit(0) { try $0.renameSpeaker($0.speakers[0].id, to: "Alice B.") }
        trigger.sessionsChanged(); await settle()
        XCTAssertEqual(requests.count, 1)
    }

    func testAStaleRunMayBeRequestedAgain() async throws {
        sessions = [ready()]
        let trigger = trigger()
        trigger.sessionsChanged(); await settle()
        trigger.runWasStale(sessions[0].id); await settle()
        XCTAssertEqual(requests.count, 2)
    }

    func testNeverRequestedOnceASummaryExistsEvenStale() async throws {
        var item = DemoContent.recordings()[0]; item.isDemo = false; item.state = .sealed; item.startedAt = Date()
        try item.renameSpeaker(item.speakers.first { !$0.confirmed }!.id, to: "Léa")
        XCTAssertTrue(item.summaryIsStale)
        sessions = [item]
        let trigger = trigger()
        trigger.sessionsChanged(); await settle()
        XCTAssertTrue(requests.isEmpty)
    }

    func testSessionsRecordedBeforeTheSettingAndTheSettingOffAreIgnored() async throws {
        let enabled = Date()
        sessions = [ready(startedAt: enabled.addingTimeInterval(-60))]
        let trigger = trigger(since: enabled)
        trigger.sessionsChanged(); await settle()
        XCTAssertTrue(requests.isEmpty, "Recorded before the setting was turned on")
        sessions = [ready(startedAt: enabled.addingTimeInterval(60))]
        trigger.sessionsChanged()
        XCTAssertFalse(trigger.waitingSessions.isEmpty)
        trigger.enabledSince = nil
        XCTAssertTrue(trigger.waitingSessions.isEmpty, "Turning the setting off stops the waits")
        await settle()
        XCTAssertTrue(requests.isEmpty)
    }

    func testASessionRecordingWhenTheSettingIsTurnedOnCounts() async throws {
        let enabled = Date()
        sessions = [ready(startedAt: enabled.addingTimeInterval(-600), duration: 300),
                    ready(startedAt: enabled.addingTimeInterval(-600), duration: 900)]
        let trigger = trigger(since: enabled)
        trigger.sessionsChanged(); await settle()
        XCTAssertEqual(requests, [sessions[1].id], "Only the session that ended after the setting was turned on")
    }

    func testTheSettingIsDatedWhenTurnedOn() {
        let store = InMemorySettings()
        let settings = SummarySettings(store: store, usesSystem: false, notifier: RecordingNotifier())
        XCTAssertFalse(settings.automatic)
        XCTAssertNil(settings.automaticSince)
        settings.automatic = true
        XCTAssertNotNil(settings.automaticSince)
        settings.automatic = false
        XCTAssertNil(settings.automaticSince)
        store.set(true, for: .summaryAutomatic); store.set(Date(timeIntervalSince1970: 0), for: .summaryAutomaticSince)
        let reloaded = SummarySettings(store: store, usesSystem: false, notifier: RecordingNotifier())
        XCTAssertTrue(reloaded.automatic)
        XCTAssertEqual(reloaded.automaticSince, Date(timeIntervalSince1970: 0))
    }
}
