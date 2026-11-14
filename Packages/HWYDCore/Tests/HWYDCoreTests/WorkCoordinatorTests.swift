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

    func testUserStartedJobsAreRefusedWithTheRunningJobAsReason() async {
        let coordinator = WorkCoordinator(), gate = Gate()
        await coordinator.request(.transcription(session: first)) { await gate.wait() }
        let busy = WorkBusy(job: .transcription(session: first))
        for job in [WorkJob.summary(session: second), .voice(session: nil), .voice(session: second), .speechModel(locale: "en-US"), .diarizer] {
            let decision = await coordinator.request(job) { XCTFail("refused job ran") }
            XCTAssertEqual(decision, .refused(.busy(busy)), "\(job)")
        }
        let again = await coordinator.request(.transcription(session: first)) {}
        XCTAssertEqual(again, .refused(.alreadyRequested(.transcription(session: first))))
        XCTAssertEqual(WorkRefusal.busy(busy).localizedDescription.isEmpty, false)
        await gate.release()
        await coordinator.idle()
    }

    func testASummaryAskedToWaitIsQueuedBehindTheRunningJob() async {
        let coordinator = WorkCoordinator(), gate = Gate()
        await coordinator.request(.transcription(session: first)) { await gate.record("transcription"); await gate.wait() }
        let decision = await coordinator.request(.summary(session: second), waits: true) { await gate.record("summary") }
        XCTAssertEqual(decision, .queued(behind: WorkBusy(job: .transcription(session: first))))
        let again = await coordinator.request(.summary(session: second)) {}
        XCTAssertEqual(again, .refused(.alreadyRequested(.summary(session: second))))
        await gate.release()
        await coordinator.idle()
        let log = await gate.log
        XCTAssertEqual(log, ["transcription", "summary"])
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

    func testDroppingQueuedJobsLeavesTheRunningOne() async {
        let coordinator = WorkCoordinator(), gate = Gate()
        await coordinator.request(.summary(session: first)) { await gate.wait(); await gate.record("first") }
        await coordinator.request(.summary(session: second), waits: true) { await gate.record("second") }
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
        try? await Task.sleep(for: .milliseconds(20))
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

    func testJobsKnowTheirSessionAndWhetherTheyWait() {
        XCTAssertEqual(WorkJob.voice(session: first).sessionID, first)
        XCTAssertNil(WorkJob.voice(session: nil).sessionID)
        XCTAssertNil(WorkJob.diarizer.sessionID)
        XCTAssertEqual(WorkJob.speechModel(locale: "fr-FR").kind, .modelInstall)
        XCTAssertTrue(WorkJob.transcription(session: first).waitsWhenBusy)
        XCTAssertFalse(WorkJob.summary(session: first).waitsWhenBusy)
    }
}
