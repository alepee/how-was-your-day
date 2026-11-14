import XCTest
@testable import HWYDCore

/// Availability of each summarizer and the factory's choice. No provider runs, no network, no keychain.
final class SummarizerTests: XCTestCase {
    private let environment = SummarizerEnvironment(
        dataDirectory: URL(fileURLWithPath: "/tmp/hwyd-summarizer-tests"),
        mcpExecutable: URL(fileURLWithPath: "/tmp/hwyd-mcp")) { _ in XCTFail("Availability never reads the key"); return nil }

    private func configuration(_ service: SummaryService, enabled: Bool = true) -> SummaryConfiguration {
        SummaryConfiguration(enabled: enabled, service: service, localModel: "fixture", hostedModel: "fixture-model", keyStored: true)
    }

    func testDisabledFeatureIsUnavailableWhateverTheService() {
        for service in SummaryService.allCases {
            let summarizer = SummarizerFactory.make(configuration(service, enabled: false), environment: environment)
            XCTAssertTrue(summarizer is UnavailableSummarizer)
            XCTAssertEqual(summarizer.availability, .unavailable(.disabled))
        }
    }

    func testFactoryChoosesTheImplementationOfTheService() {
        XCTAssertTrue(SummarizerFactory.make(configuration(.local), environment: environment) is LocalSummarizer)
        XCTAssertTrue(SummarizerFactory.make(configuration(.agent), environment: environment) is AgentSummarizer)
        for service in SummaryService.allCases where service.isRemote {
            let summarizer = SummarizerFactory.make(configuration(service), environment: environment)
            XCTAssertEqual((summarizer as? HostedSummarizer)?.service, service)
            XCTAssertEqual(summarizer.availability, .ready)
        }
    }

    func testLocalNeedsALoopbackAddressAndAModel() {
        func availability(_ endpoint: String, model: String = "fixture") -> SummaryAvailability {
            LocalSummarizer(endpoint: endpoint, model: model, contextTokens: 32768, reasoningDisabled: false, environment: environment).availability
        }
        XCTAssertEqual(availability("http://127.0.0.1:1234/v1"), .ready)
        XCTAssertEqual(availability("http://localhost:11434/v1"), .ready)
        XCTAssertEqual(availability("https://example.com/v1"), .unavailable(.localServerNotConfigured))
        XCTAssertEqual(availability("not a url"), .unavailable(.localServerNotConfigured))
        XCTAssertEqual(availability("http://127.0.0.1:1234/v1", model: "  "), .unavailable(.localServerNotConfigured))
    }

    func testLocalInputLimitFollowsTheLoadedContext() {
        func limit(_ tokens: Int) -> Int {
            LocalSummarizer(endpoint: "http://127.0.0.1:1234/v1", model: "m", contextTokens: tokens, reasoningDisabled: false, environment: environment).inputCharacterLimit
        }
        XCTAssertEqual(limit(16384), 12_768)
        XCTAssertEqual(limit(32768), 45_536)
        XCTAssertEqual(limit(8192), 12_000)
    }

    func testHostedNeedsAStoredKeyThenAModel() {
        XCTAssertEqual(HostedSummarizer(service: .mistral, model: "m", keyStored: false, environment: environment).availability,
                       .unavailable(.apiKeyMissing(.mistral)))
        XCTAssertEqual(HostedSummarizer(service: .openai, model: "", keyStored: false, environment: environment).availability,
                       .unavailable(.apiKeyMissing(.openai)))
        XCTAssertEqual(HostedSummarizer(service: .anthropic, model: " ", keyStored: true, environment: environment).availability,
                       .unavailable(.modelMissing(.anthropic)))
    }

    func testAgentNeedsACommand() {
        XCTAssertEqual(AgentSummarizer(command: "claude-agent-acp", directory: "~", environment: environment).availability, .ready)
        XCTAssertEqual(AgentSummarizer(command: "  ", directory: "~", environment: environment).availability, .unavailable(.agentCommandMissing))
        XCTAssertEqual(AgentSummarizer(command: "x", directory: "~/Notes", environment: environment).workingDirectory.path,
                       (NSHomeDirectory() as NSString).appendingPathComponent("Notes"))
    }

    func testReasonsReuseTheSettingsMessages() {
        XCTAssertEqual(SummaryUnavailability.localServerNotConfigured.localizedDescription, SummaryFailure.invalidEndpoint.localizedDescription)
        XCTAssertEqual(SummaryUnavailability.apiKeyMissing(.gemini).localizedDescription, SummaryFailure.apiKeyMissing("Google Gemini").localizedDescription)
        XCTAssertEqual(SummaryUnavailability.agentCommandMissing.localizedDescription, AgentSummaryFailure.commandMissing.localizedDescription)
        XCTAssertNil(SummaryAvailability.ready.reason)
        XCTAssertNotNil(SummaryAvailability.unavailable(.disabled).reason)
    }

    func testUnavailableSummarizersRefuseToRunWithoutReadingTheKey() async {
        let recording = Recording(title: "Fixture", isDemo: true)
        let summarizers: [any Summarizer] = [
            UnavailableSummarizer(reason: .disabled),
            LocalSummarizer(endpoint: "https://example.com/v1", model: "m", contextTokens: 32768, reasoningDisabled: false, environment: environment),
            HostedSummarizer(service: .mistral, model: "m", keyStored: false, environment: environment),
            AgentSummarizer(command: "", directory: "~", environment: environment),
        ]
        for summarizer in summarizers {
            do {
                _ = try await summarizer.summarize(recording) { _ in }
                XCTFail("\(type(of: summarizer)) ran while unavailable")
            } catch let reason as SummaryUnavailability {
                XCTAssertEqual(summarizer.availability, .unavailable(reason))
            } catch { XCTFail("Unexpected error \(error)") }
        }
    }

    func testHostedReadsTheKeyOnlyWhenItRuns() async {
        let missing = SummarizerEnvironment(dataDirectory: environment.dataDirectory, mcpExecutable: environment.mcpExecutable) { _ in nil }
        let summarizer = HostedSummarizer(service: .openai, model: "m", keyStored: true, environment: missing)
        XCTAssertEqual(summarizer.availability, .ready)
        do {
            _ = try await summarizer.summarize(Recording(title: "Fixture", isDemo: true)) { _ in }
            XCTFail("Ran without a key")
        } catch { XCTAssertEqual(error as? SummaryUnavailability, .apiKeyMissing(.openai)) }
    }
}
