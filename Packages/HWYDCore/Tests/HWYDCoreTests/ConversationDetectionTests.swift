import Combine
import XCTest
@testable import HWYDCore

private let gather = ConversationApp(id: "com.gather.GatherV2", name: "Gather")
private let chrome = ConversationApp(id: "com.google.Chrome", name: "Google Chrome")
private let handy = ConversationApp(id: "com.pais.handy", name: "Handy")

private func microphone(_ app: ConversationApp) -> AppAudioActivity { AppAudioActivity(app: app, readsMicrophone: true, playsAudio: false) }
private func sound(_ app: ConversationApp) -> AppAudioActivity { AppAudioActivity(app: app, readsMicrophone: false, playsAudio: true) }

final class ConversationAppTests: XCTestCase {
    func testHelperBelongsToTheOutermostApp() {
        XCTAssertEqual(ConversationApp.bundlePath(ofExecutable: "/Applications/GatherV2.app/Contents/Frameworks/GatherV2 Helper.app/Contents/MacOS/GatherV2 Helper"),
                       "/Applications/GatherV2.app")
        XCTAssertEqual(ConversationApp.bundlePath(ofExecutable: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/158.0.8127.38/Helpers/Google Chrome Helper (Aperitif).app/Contents/MacOS/Google Chrome Helper (Aperitif)"),
                       "/Applications/Google Chrome.app")
    }

    func testAppExecutableBelongsToItsBundle() {
        XCTAssertEqual(ConversationApp.bundlePath(ofExecutable: "/Applications/Handy.app/Contents/MacOS/handy"), "/Applications/Handy.app")
    }

    func testCommandLineToolHasNoApp() {
        XCTAssertNil(ConversationApp.bundlePath(ofExecutable: "/usr/bin/afplay"))
        XCTAssertNil(ConversationApp.bundlePath(ofExecutable: "/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd"))
    }
}

final class ConversationStartWatchTests: XCTestCase {
    private var watch = ConversationStartWatch(policy: ConversationStartPolicy(settle: 8, release: 60))

    func testMicrophoneHeldLongEnoughIsProposed() {
        XCTAssertNil(watch.observe([microphone(gather)], capturing: false, now: 0))
        XCTAssertNil(watch.observe([microphone(gather)], capturing: false, now: 7.9))
        XCTAssertEqual(watch.observe([microphone(gather)], capturing: false, now: 8), gather)
    }

    func testShortDictationIsNotProposed() {
        XCTAssertNil(watch.observe([microphone(handy)], capturing: false, now: 0))
        XCTAssertNil(watch.observe([sound(handy)], capturing: false, now: 3))
        XCTAssertNil(watch.observe([sound(handy)], capturing: false, now: 20))
    }

    func testTwoShortDictationsDoNotAddUp() {
        _ = watch.observe([microphone(handy)], capturing: false, now: 0)
        _ = watch.observe([], capturing: false, now: 5)
        XCTAssertNil(watch.observe([microphone(handy)], capturing: false, now: 6))
        XCTAssertNil(watch.observe([microphone(handy)], capturing: false, now: 10), "Four seconds since the microphone opened again")
    }

    func testHelpersOfOneAppCountTogether() {
        _ = watch.observe([sound(chrome), microphone(chrome)], capturing: false, now: 0)
        XCTAssertEqual(watch.observe([sound(chrome), microphone(chrome)], capturing: false, now: 8), chrome)
    }

    func testProposalStandsWhileTheAppMutes() {
        _ = watch.observe([microphone(gather)], capturing: false, now: 0)
        _ = watch.observe([microphone(gather)], capturing: false, now: 8)
        XCTAssertEqual(watch.observe([sound(gather)], capturing: false, now: 30), gather)
    }

    func testAnsweredProposalDoesNotComeBackOnUnmute() {
        _ = watch.observe([microphone(gather)], capturing: false, now: 0)
        _ = watch.observe([microphone(gather)], capturing: false, now: 8)
        watch.dismiss()
        XCTAssertNil(watch.observe([sound(gather)], capturing: false, now: 20))
        XCTAssertNil(watch.observe([microphone(gather)], capturing: false, now: 40))
        XCTAssertNil(watch.observe([microphone(gather)], capturing: false, now: 100))
    }

    func testAppQuietForAMinuteIsProposedAgain() {
        _ = watch.observe([microphone(gather)], capturing: false, now: 0)
        _ = watch.observe([microphone(gather)], capturing: false, now: 8)
        watch.dismiss()
        XCTAssertNil(watch.observe([], capturing: false, now: 10))
        XCTAssertNil(watch.observe([microphone(gather)], capturing: false, now: 71), "Quiet for 61 seconds: a new conversation starts")
        XCTAssertEqual(watch.observe([microphone(gather)], capturing: false, now: 79), gather)
    }

    func testUnansweredProposalIsWithdrawnOnceTheAppIsQuiet() {
        _ = watch.observe([microphone(gather)], capturing: false, now: 0)
        _ = watch.observe([microphone(gather)], capturing: false, now: 8)
        XCTAssertEqual(watch.observe([], capturing: false, now: 10), gather)
        XCTAssertEqual(watch.observe([], capturing: false, now: 69), gather)
        XCTAssertNil(watch.observe([], capturing: false, now: 70))
        XCTAssertFalse(watch.isTracking)
    }

    func testSoundKeepsTheConversationAlive() {
        _ = watch.observe([microphone(gather)], capturing: false, now: 0)
        _ = watch.observe([microphone(gather)], capturing: false, now: 8)
        watch.dismiss()
        _ = watch.observe([sound(gather)], capturing: false, now: 10)
        XCTAssertNil(watch.observe([microphone(gather)], capturing: false, now: 200))
        XCTAssertNil(watch.observe([microphone(gather)], capturing: false, now: 208), "The app never went quiet: same conversation")
    }

    func testNothingIsProposedDuringACapture() {
        XCTAssertNil(watch.observe([microphone(gather)], capturing: true, now: 0))
        XCTAssertNil(watch.observe([microphone(gather)], capturing: true, now: 30))
    }

    func testConversationRecordedOnceIsNotProposedAfterTheCapture() {
        _ = watch.observe([microphone(gather)], capturing: true, now: 0)
        XCTAssertNil(watch.observe([microphone(gather)], capturing: false, now: 30))
        XCTAssertNil(watch.observe([microphone(gather)], capturing: false, now: 60))
    }

    func testConversationRecordedWhileMutedIsNotProposedAfterTheCapture() {
        _ = watch.observe([microphone(gather)], capturing: false, now: 0)
        _ = watch.observe([sound(gather)], capturing: true, now: 3)
        _ = watch.observe([sound(gather)], capturing: true, now: 300)
        XCTAssertNil(watch.observe([microphone(gather)], capturing: false, now: 310))
        XCTAssertNil(watch.observe([microphone(gather)], capturing: false, now: 320))
    }

    func testCaptureWithdrawsTheProposal() {
        _ = watch.observe([microphone(gather)], capturing: false, now: 0)
        _ = watch.observe([microphone(gather)], capturing: false, now: 8)
        XCTAssertNil(watch.observe([microphone(gather)], capturing: true, now: 9))
        XCTAssertNil(watch.observe([microphone(gather)], capturing: false, now: 20))
    }

    func testOneProposalAtATime() {
        _ = watch.observe([microphone(gather)], capturing: false, now: 0)
        _ = watch.observe([microphone(gather), microphone(chrome)], capturing: false, now: 8)
        XCTAssertEqual(watch.observe([microphone(gather), microphone(chrome)], capturing: false, now: 20), gather)
        watch.dismiss()
        XCTAssertEqual(watch.observe([microphone(gather), microphone(chrome)], capturing: false, now: 21), chrome)
    }

    func testTracksWhileAnAppIsInAConversation() {
        XCTAssertFalse(watch.isTracking)
        _ = watch.observe([microphone(handy)], capturing: false, now: 0)
        XCTAssertTrue(watch.isTracking)
        _ = watch.observe([], capturing: false, now: 3)
        XCTAssertTrue(watch.isTracking)
        _ = watch.observe([], capturing: false, now: 63)
        XCTAssertFalse(watch.isTracking)
    }
}

@MainActor
final class ConversationDetectorTests: XCTestCase {
    private var time: TimeInterval = 100
    private let activity = FixedAudioActivity()

    private func detector() -> ConversationDetector {
        ConversationDetector(activity: activity, policy: ConversationStartPolicy(settle: 8, release: 60), now: { [unowned self] in time })
    }

    func testProposesTheAppHoldingTheMicrophone() {
        let detector = detector()
        activity.report([microphone(gather)])
        XCTAssertNil(detector.proposal)
        XCTAssertEqual(activity.attention, .closely)
        time += 8
        activity.report([microphone(gather)])
        XCTAssertEqual(detector.proposal?.app, gather)
    }

    func testSameProposalIsNotPublishedAgain() {
        let detector = detector()
        var published: [ConversationProposal?] = []
        let changes = detector.$proposal.dropFirst().sink { published.append($0) }
        activity.report([microphone(gather)])
        time += 8
        activity.report([microphone(gather)])
        time += 2
        activity.report([microphone(gather)])
        XCTAssertEqual(published.count, 1)
        changes.cancel()
    }

    func testAnsweringWithdrawsTheProposal() {
        let detector = detector()
        activity.report([microphone(gather)])
        time += 8
        activity.report([microphone(gather)])
        detector.answer()
        XCTAssertNil(detector.proposal)
        time += 2
        activity.report([microphone(gather)])
        XCTAssertNil(detector.proposal)
    }

    func testCaptureWithdrawsTheProposalAtOnce() {
        let detector = detector()
        activity.report([microphone(gather)])
        time += 8
        activity.report([microphone(gather)])
        detector.isCapturing = true
        XCTAssertNil(detector.proposal)
    }

    func testTurnedOffProposesNothingAndStopsWatching() {
        let detector = detector()
        activity.report([microphone(gather)])
        time += 8
        activity.report([microphone(gather)])
        detector.isEnabled = false
        XCTAssertNil(detector.proposal)
        XCTAssertEqual(activity.attention, .off)
        time += 10
        activity.report([microphone(gather)])
        XCTAssertNil(detector.proposal)
    }

    func testStartedOffLooksAtNothing() {
        let detector = ConversationDetector(activity: activity, enabled: false, now: { [unowned self] in time })
        XCTAssertEqual(activity.attention, .off)
        activity.report([microphone(gather)])
        time += 8
        activity.report([microphone(gather)])
        XCTAssertNil(detector.proposal)
    }

    func testTurnedOnAgainStartsFromScratch() {
        let detector = detector()
        detector.isEnabled = false
        activity.report([microphone(gather)])
        time += 30
        detector.isEnabled = true
        activity.report([microphone(gather)])
        XCTAssertNil(detector.proposal, "The eight seconds count from the moment detection is on")
        time += 8
        activity.report([microphone(gather)])
        XCTAssertEqual(detector.proposal?.app, gather)
    }

    func testStopsWatchingCloselyOnceEveryAppIsQuiet() {
        let detector = detector()
        activity.report([microphone(handy)])
        XCTAssertEqual(activity.attention, .closely)
        time += 3
        activity.report([])
        time += 60
        activity.report([])
        XCTAssertEqual(activity.attention, .changes)
        XCTAssertNil(detector.proposal)
    }
}
