import XCTest
@testable import HWYDCore

final class WorkCoordinatorTests: XCTestCase {
    /// A job that runs until the test opens its gate, and records the order jobs ran in.
    private actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var log: [String] = []
        func record(_ entry: String) { log.append(entry) }
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
    }

    private let first = UUID(), second = UUID()

    func testOneJobRunsAtATimeAndATranscriptionWaitsItsTurn() async {
        let coordinator = WorkCoordinator(), gate = Gate()
        let started = await coordinator.request(.summary(session: first)) {
            await gate.record("summary"); await gate.wait()
        }
        XCTAssertEqual(started, .accepted)
        let busy = WorkBusy(job: .summary(session: first))
        let queued = await coordinator.request(.transcription(session: second)) { await gate.record("transcription") }
        XCTAssertEqual(queued, .queued(behind: busy))
        let snapshot = await coordinator.snapshot
        XCTAssertEqual(snapshot.running, .summary(session: first))
        XCTAssertEqual(snapshot.queued, [.transcription(session: second)])
        XCTAssertTrue(snapshot.isQueued(.transcription(session: second)))
        XCTAssertEqual(snapshot.jobs(for: second), [.transcription(session: second)])
        XCTAssertEqual(snapshot.availability, .busy(busy))
        await gate.release()
        await coordinator.idle()
        let log = await gate.log
        XCTAssertEqual(log, ["summary", "transcription"])
        let after = await coordinator.snapshot
        XCTAssertFalse(after.isBusy)
        XCTAssertEqual(after.availability, .ready)
    }

    func testEveryHeavyJobWaitsItsTurnInTheOrderAsked() async {
        let coordinator = WorkCoordinator(), gate = Gate()
        await coordinator.request(.transcription(session: first)) { await gate.record("transcription"); await gate.wait() }
        let busy = WorkBusy(job: .transcription(session: first))
        let jobs: [(WorkJob, String)] = [(.summary(session: second), "summary"), (.enrollment(session: second, person: first), "enrollment"),
                                         (.voice(session: second), "identification"), (.speechModel(locale: "en-US"), "model"), (.diarizer, "diarizer")]
        for (job, name) in jobs {
            let decision = await coordinator.request(job) { await gate.record(name) }
            XCTAssertEqual(decision, .queued(behind: busy), "\(job)")
        }
        let again = await coordinator.request(.summary(session: second)) {}
        XCTAssertEqual(again, .refused(.alreadyRequested(.summary(session: second))))
        await gate.release()
        await coordinator.idle()
        let log = await gate.log
        XCTAssertEqual(log, ["transcription", "summary", "enrollment", "identification", "model", "diarizer"])
    }

    func testAVoicePrintChangeRunsBesideATranscription() async {
        let coordinator = WorkCoordinator(), gate = Gate()
        await coordinator.request(.transcription(session: first)) { await gate.wait(); await gate.record("transcription") }
        let erasure = WorkJob.voicePrint(person: second, change: .oppose)
        let decision = await coordinator.request(erasure) { await gate.record("opposition") }
        XCTAssertEqual(decision, .accepted)
        // The opposition ends while the transcription still runs.
        while await coordinator.snapshot.runningVoicePrint != nil { await Task.yield() }
        let snapshot = await coordinator.snapshot
        XCTAssertEqual(snapshot.running, .transcription(session: first))
        XCTAssertEqual(snapshot.availability, .busy(WorkBusy(job: .transcription(session: first))))
        await gate.release()
        await coordinator.idle()
        let log = await gate.log
        XCTAssertEqual(log, ["opposition", "transcription"])
    }

    func testAVoicePrintChangeAndAVoiceJobNeverRunTogether() async {
        let coordinator = WorkCoordinator(), gate = Gate()
        let enrollment = WorkJob.enrollment(session: first, person: second)
        await coordinator.request(enrollment) { await gate.record("enrollment"); await gate.wait() }
        let erasure = WorkJob.voicePrint(person: second, change: .forget)
        let decision = await coordinator.request(erasure) { await gate.record("erasure") }
        XCTAssertEqual(decision, .queued(behind: WorkBusy(job: enrollment)))
        // A voice job asked meanwhile waits behind the enrollment, and then for the erasure.
        await coordinator.request(.voice(session: first)) { await gate.record("identification") }
        await gate.release()
        await coordinator.idle()
        let log = await gate.log
        XCTAssertEqual(log, ["enrollment", "erasure", "identification"])
    }

    func testVoicePrintChangesRunOneAtATimeInOrder() async {
        let coordinator = WorkCoordinator(), gate = Gate()
        let forget = WorkJob.voicePrint(person: first, change: .forget)
        await coordinator.request(forget) { await gate.record("forget"); await gate.wait() }
        let decision = await coordinator.request(.voicePrint(person: second, change: .withdraw(session: nil))) { await gate.record("withdraw") }
        XCTAssertEqual(decision, .queued(behind: WorkBusy(job: forget)))
        let other = await coordinator.request(.voicePrint(person: second, change: .withdraw(session: first))) { await gate.record("withdraw session") }
        XCTAssertEqual(other, .queued(behind: WorkBusy(job: forget)), "another session is another job")
        await gate.release()
        await coordinator.idle()
        let log = await gate.log
        XCTAssertEqual(log, ["forget", "withdraw", "withdraw session"])
    }

    func testCancelReturnsWhatItCancelled() async {
        let coordinator = WorkCoordinator(), gate = Gate()
        let running = WorkJob.enrollment(session: first, person: first), waiting = WorkJob.enrollment(session: second, person: first)
        await coordinator.request(running) { await gate.wait() }
        await coordinator.request(waiting) { XCTFail("dropped job ran") }
        await coordinator.request(.summary(session: first)) {}
        let person = first
        let cancelled = await coordinator.cancel { $0.personID == person }
        XCTAssertEqual(cancelled, [running, waiting])
        let again = await coordinator.cancel { $0.personID == person }
        XCTAssertEqual(again, [], "a cancelled run is not cancelled twice")
        await gate.release()
        await coordinator.idle()
    }

    func testCancellingStopsTheRunningJobAndDropsWaitingOnes() async {
        let coordinator = WorkCoordinator(), gate = Gate()
        await coordinator.request(.transcription(session: first)) {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            await gate.record("cancelled")
        }
        await coordinator.request(.transcription(session: second)) { await gate.record("dropped job ran") }
        await coordinator.cancel(.transcription(session: second))
        let waiting = await coordinator.snapshot.queued
        XCTAssertEqual(waiting, [])
        await coordinator.cancelAll()
        await coordinator.idle()
        let log = await gate.log
        XCTAssertEqual(log, ["cancelled"])
    }

    func testTheSameJobAskedWhileItsCancelledRunEndsWaitsForIt() async {
        let coordinator = WorkCoordinator(), gate = Gate()
        let job = WorkJob.transcription(session: first)
        _ = await coordinator.request(job) { await gate.record("cancelled"); await gate.wait() }
        let again = await coordinator.request(job) { await gate.record("again") }
        XCTAssertEqual(again, .refused(.alreadyRequested(job)), "not while the run goes on")
        await coordinator.cancel(job)
        let queued = await coordinator.request(job) { await gate.record("again") }
        XCTAssertEqual(queued, .queued(behind: WorkBusy(job: job)))
        let twice = await coordinator.request(job) { await gate.record("twice") }
        XCTAssertEqual(twice, .refused(.alreadyRequested(job)))
        await gate.release()
        await coordinator.idle()
        let log = await gate.log
        XCTAssertEqual(log, ["cancelled", "again"])
    }

    func testDroppingQueuedJobsLeavesTheRunningOne() async {
        let coordinator = WorkCoordinator(), gate = Gate()
        await coordinator.request(.summary(session: first)) { await gate.wait(); await gate.record("first") }
        await coordinator.request(.summary(session: second)) { await gate.record("second") }
        await coordinator.dropQueued { $0.kind == .summary }
        let snapshot = await coordinator.snapshot
        XCTAssertEqual(snapshot.running, .summary(session: first))
        XCTAssertTrue(snapshot.queued.isEmpty)
        await gate.release()
        await coordinator.idle()
        let log = await gate.log
        XCTAssertEqual(log, ["first"])
    }

    func testAJobQueuedByARunningJobRunsNext() async {
        let coordinator = WorkCoordinator(), gate = Gate(), session = first
        await coordinator.request(.speechModel(locale: "en-US")) {
            await gate.record("install")
            let decision = await coordinator.request(.transcription(session: session)) { await gate.record("transcription") }
            XCTAssertEqual(decision, .queued(behind: WorkBusy(job: .speechModel(locale: "en-US"))))
        }
        await coordinator.idle()
        let log = await gate.log
        XCTAssertEqual(log, ["install", "transcription"])
    }

    func testBusyStreamReportsOnlyFlips() async {
        let coordinator = WorkCoordinator(), gate = Gate()
        var changes = await coordinator.busyChanges().makeAsyncIterator()
        let initial = await changes.next()
        XCTAssertEqual(initial, false)
        await coordinator.request(.summary(session: first)) { await gate.wait() }
        await coordinator.request(.transcription(session: second)) {}
        let busy = await changes.next()
        XCTAssertEqual(busy, true)
        await gate.release()
        let idle = await changes.next()
        XCTAssertEqual(idle, false, "the queued transcription keeps the coordinator busy until it ends")
        let snapshot = await coordinator.snapshot
        XCTAssertFalse(snapshot.isBusy)
    }

    func testSnapshotsGrowInRevision() async {
        let coordinator = WorkCoordinator()
        var snapshots = await coordinator.snapshots().makeAsyncIterator()
        let initial = await snapshots.next()
        XCTAssertEqual(initial?.revision, 0)
        await coordinator.request(.diarizer) {}
        await coordinator.idle()
        let started = await snapshots.next(), ended = await snapshots.next()
        XCTAssertEqual(started?.running, .diarizer)
        XCTAssertNil(ended?.running)
        XCTAssertLessThan(started?.revision ?? 0, ended?.revision ?? 0)
    }

    func testIdleReturnsWhenItsTaskIsCancelled() async {
        let coordinator = WorkCoordinator(), gate = Gate()
        await coordinator.request(.diarizer) { await gate.wait() }
        let waiter = Task { await coordinator.idle() }
        // Cancelled while it waits, not before.
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await coordinator.idleWaiterCount == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        let waiting = await coordinator.idleWaiterCount
        XCTAssertEqual(waiting, 1)
        waiter.cancel()
        await waiter.value
        let busy = await coordinator.snapshot.isBusy
        XCTAssertTrue(busy)
        await gate.release()
        await coordinator.idle()
    }

    func testAServiceConditionComesBeforeBusy() {
        let busy = Availability<Never>.busy(WorkBusy(job: .diarizer))
        XCTAssertEqual(SummaryAvailability.ready.combined(with: busy), .busy(WorkBusy(job: .diarizer)))
        XCTAssertEqual(SummaryAvailability.unavailable(.disabled).combined(with: busy), .unavailable(.disabled))
        XCTAssertEqual(SummaryAvailability.ready.combined(with: .ready), .ready)
        XCTAssertNotNil(SummaryAvailability.ready.combined(with: busy).reason)
    }

    func testJobsKnowTheirSessionLaneAndConflicts() {
        XCTAssertEqual(WorkJob.voice(session: first).sessionID, first)
        XCTAssertNil(WorkJob.voice(session: nil).sessionID)
        XCTAssertNil(WorkJob.diarizer.sessionID)
        XCTAssertEqual(WorkJob.enrollment(session: first, person: second).sessionID, first)
        XCTAssertEqual(WorkJob.enrollment(session: first, person: second).personID, second)
        XCTAssertNil(WorkJob.voicePrint(person: second, change: .withdraw(session: first)).sessionID, "a print change reads no session")
        XCTAssertEqual(WorkJob.speechModel(locale: "fr-FR").kind, .modelInstall)
        XCTAssertEqual(WorkJob.voicePrint(person: first, change: .forget).lane, .voicePrints)
        XCTAssertEqual(WorkJob.transcription(session: first).lane, .heavy)
        let change = WorkJob.voicePrint(person: first, change: .oppose)
        XCTAssertTrue(change.conflicts(with: .voice(session: nil)))
        XCTAssertTrue(WorkJob.enrollment(session: first, person: second).conflicts(with: change))
        XCTAssertFalse(change.conflicts(with: .transcription(session: first)))
        XCTAssertFalse(change.conflicts(with: .voicePrint(person: second, change: .forget)), "same lane: ordered, not a conflict")
    }
}
