import XCTest
@testable import HWYDCore

/// Typed preferences: defaults, stored formats of earlier versions, and the two adapters.
final class SettingsTests: XCTestCase {
    func testMissingOrInvalidValuesFallBackToTheKeyDefault() {
        let store = InMemorySettings(["summary.service": "unknown-provider", "newSession.kind": 42])
        XCTAssertEqual(store.value(.summaryService), .local)
        XCTAssertEqual(store.value(.newSessionKind), .adHoc)
        XCTAssertEqual(store.value(.summaryEndpoint), "http://127.0.0.1:1234/v1")
        XCTAssertEqual(store.value(.summaryContextTokens), 32768)
        XCTAssertNil(store.value(.appearance))
        XCTAssertFalse(store.value(.diarizationEnabled))
        XCTAssertTrue(store.contains(.summaryService))
        XCTAssertFalse(store.contains(.diarizationEnabled))
    }

    func testValuesRoundTripAndRemove() {
        let store = InMemorySettings()
        store.set(.anthropic, for: .summaryService)
        store.set("claude-test", for: .summaryHostedModel(.anthropic))
        store.set(["a", "b"], for: .calendarSelection)
        store.set(Data(), for: .recordingShortcut)
        XCTAssertEqual(store.value(.summaryService), .anthropic)
        XCTAssertEqual(store.value(.summaryHostedModel(.anthropic)), "claude-test")
        XCTAssertNil(store.value(.summaryHostedModel(.openai)))
        XCTAssertEqual(store.value(.calendarSelection), ["a", "b"])
        XCTAssertEqual(store.value(.recordingShortcut), Data())
        store.set(nil, for: .summaryHostedModel(.anthropic))
        XCTAssertFalse(store.contains(.summaryHostedModel(.anthropic)))
        store.remove(.calendarSelection)
        XCTAssertEqual(store.value(.calendarSelection), [])
    }

    /// The UserDefaults adapter reads what `UserDefaults.set` wrote in earlier versions, under the same names.
    func testUserDefaultsAdapterKeepsTheExistingKeysAndFormats() throws {
        let suite = "HWYDSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "diarizationEnabled")
        defaults.set(65536, forKey: "summary.contextTokens")
        defaults.set("agent", forKey: "summary.service")
        defaults.set("voice-memo", forKey: "newSession.kind")
        defaults.set("dark", forKey: "appearancePreference")
        defaults.set("YES", forKey: "calendar.enabled")
        let store = UserDefaultsSettings(defaults)
        XCTAssertTrue(store.value(.diarizationEnabled))
        XCTAssertEqual(store.value(.summaryContextTokens), 65536)
        XCTAssertEqual(store.value(.summaryService), .agent)
        XCTAssertEqual(store.value(.newSessionKind), .voiceMemo)
        XCTAssertEqual(store.value(.appearance), "dark")
        XCTAssertTrue(store.value(.calendarEnabled))
        store.set(false, for: .diarizationEnabled)
        store.set(.call, for: .newSessionKind)
        XCTAssertEqual(defaults.object(forKey: "diarizationEnabled") as? Bool, false)
        XCTAssertEqual(defaults.string(forKey: "newSession.kind"), "call")
        store.remove(.appearance)
        XCTAssertNil(defaults.object(forKey: "appearancePreference"))
    }
}
