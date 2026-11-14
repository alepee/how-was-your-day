import XCTest
@testable import HWYDCore

/// Summary settings over an in-memory store. `usesSystem: false` keeps the keychain and the network out.
@MainActor final class SummarySettingsTests: XCTestCase {
    func testLoadsStoredValuesAndDefaults() {
        let store = InMemorySettings(["summary.enabled": true, "summary.service": "mistral", "summary.model.mistral": "mistral-small",
                                      "summary.contextTokens": 0, "summary.agent.command": "codex-acp"])
        let settings = SummarySettings(store: store, usesSystem: false, notifier: RecordingNotifier())
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.service, .mistral)
        XCTAssertEqual(settings.hostedModel, "mistral-small")
        XCTAssertEqual(settings.contextTokens, 32768, "Zero, written by early versions, means the default")
        XCTAssertEqual(settings.endpoint, "http://127.0.0.1:1234/v1")
        XCTAssertEqual(settings.agentDirectory, "~")
        XCTAssertFalse(settings.keyStored, "Previews and tests never read the keychain")
        XCTAssertEqual(settings.configuration, SummaryConfiguration(enabled: true, service: .mistral, hostedModel: "mistral-small", agentCommand: "codex-acp"))
    }

    func testSelectingAProviderLoadsItsOwnModel() {
        let store = InMemorySettings(["summary.model.openai": "gpt-test"])
        let settings = SummarySettings(store: store, usesSystem: false, notifier: RecordingNotifier())
        XCTAssertEqual(settings.hostedModel, "")
        settings.select(.openai)
        XCTAssertEqual(settings.hostedModel, "gpt-test")
        settings.select(.anthropic)
        XCTAssertEqual(settings.hostedModel, SummaryService.anthropic.defaultModel)
        settings.select(.agent)
        XCTAssertEqual(settings.hostedModel, "")
    }

    func testSavesOnlyForTheInstalledAppOutsideDemo() {
        let store = InMemorySettings()
        let preview = SummarySettings(store: store, usesSystem: false, notifier: RecordingNotifier())
        preview.enabled = true; preview.save()
        XCTAssertFalse(store.contains(.summaryEnabled))

        let settings = SummarySettings(store: store, usesSystem: true, notifier: RecordingNotifier())
        settings.isDemo = true
        settings.enabled = true; settings.save()
        XCTAssertFalse(store.contains(.summaryEnabled))
        settings.isDemo = false
        settings.endpoint = "http://localhost:11434/v1"; settings.localModel = "qwen"; settings.save()
        XCTAssertTrue(store.value(.summaryEnabled))
        XCTAssertEqual(store.value(.summaryEndpoint), "http://localhost:11434/v1")
        XCTAssertEqual(store.value(.summaryLocalModel), "qwen")
        XCTAssertEqual(store.value(.summaryService), .local)
        XCTAssertFalse(store.contains(.summaryHostedModel(.local)))
    }

    func testAListedModelReplacesOnlyTheSuggestedDefault() {
        let settings = SummarySettings(store: InMemorySettings(["summary.service": "gemini"]), usesSystem: false, notifier: RecordingNotifier())
        XCTAssertEqual(settings.hostedModel, SummaryService.gemini.defaultModel)
        settings.applyAvailableModels(["gemini-pro"])
        XCTAssertEqual(settings.hostedModel, "")
        settings.hostedModel = "typed-by-user"
        settings.applyAvailableModels(["gemini-pro"])
        XCTAssertEqual(settings.hostedModel, "typed-by-user")
    }

    func testAgentDetectionAsksTheInjectedDiscoveryOutsideDemo() async throws {
        let settings = SummarySettings(store: InMemorySettings(), usesSystem: false, notifier: RecordingNotifier(), discovery: FixedAgentDiscovery(["codex-acp"]))
        settings.isDemo = true
        settings.detectAgents()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(settings.detectedAgents, [])
        settings.isDemo = false
        settings.detectAgents()
        for _ in 0..<100 where settings.detectedAgents.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(settings.detectedAgents, ["codex-acp"])
    }
}
