import XCTest
@testable import HWYDCore

final class OnboardingProgressTests: XCTestCase {
    func testOpensOnFirstLaunchWithAnEmptyLibrary() {
        let progress = OnboardingProgress(settings: InMemorySettings())
        XCTAssertTrue(progress.presentsOnLaunch(hasSessions: false))
    }

    func testStaysClosedForSomeoneWhoAlreadyRecords() {
        let progress = OnboardingProgress(settings: InMemorySettings())
        XCTAssertFalse(progress.presentsOnLaunch(hasSessions: true))
    }

    func testStaysClosedOnceSeen() {
        let settings = InMemorySettings()
        OnboardingProgress(settings: settings).markSeen()
        XCTAssertEqual(settings.value(.onboardingVersion), OnboardingProgress.currentVersion)
        XCTAssertFalse(OnboardingProgress(settings: settings).presentsOnLaunch(hasSessions: false))
    }

    func testAnEarlierTourDoesNotCountAsSeen() {
        let settings = InMemorySettings(["onboarding.version": OnboardingProgress.currentVersion - 1])
        XCTAssertTrue(OnboardingProgress(settings: settings).presentsOnLaunch(hasSessions: false))
    }

    func testStepsFollowEachOther() {
        XCTAssertNil(OnboardingStep.record.previous)
        XCTAssertEqual(OnboardingStep.record.next, .calendar)
        XCTAssertEqual(OnboardingStep.calendar.next, .transcription)
        XCTAssertEqual(OnboardingStep.context.previous, .summary)
        XCTAssertNil(OnboardingStep.context.next)
    }
}
