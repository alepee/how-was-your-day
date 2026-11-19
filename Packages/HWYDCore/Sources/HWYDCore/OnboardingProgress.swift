import Foundation

/// The welcome tour: one feature per step, with the control that turns it on.
public enum OnboardingStep: Int, CaseIterable, Sendable {
    case record, calendar, transcription, voices, summary, context

    public var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    public var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
}

/// Whether the tour opens on its own, and what records that it was seen.
public struct OnboardingProgress {
    /// Raised when the tour gains steps worth showing to people who completed an earlier one.
    public static let currentVersion = 1
    private let settings: SettingsStore

    public init(settings: SettingsStore) { self.settings = settings }

    public var seenVersion: Int { settings.value(.onboardingVersion) }

    /// Opens on launch for someone who never saw it and has no session yet. Someone who already
    /// records found their way without it: the tour stays available from the settings.
    public func presentsOnLaunch(hasSessions: Bool) -> Bool {
        seenVersion < Self.currentVersion && !hasSessions
    }

    /// Completed or skipped: either way, it does not open on its own again.
    public func markSeen() { settings.set(Self.currentVersion, for: .onboardingVersion) }
}
