import Foundation

/// Every summary setting, as one value. The app builds it from its preferences; a `Summarizer`
/// is made from it and owns what the settings mean.
public struct SummaryConfiguration: Equatable, Sendable {
    public var enabled: Bool
    public var service: SummaryService
    /// OpenAI-compatible server on this Mac.
    public var localEndpoint: String
    public var localModel: String
    public var contextTokens: Int
    public var reasoningDisabled: Bool
    /// Model of the hosted provider selected by `service`.
    public var hostedModel: String
    /// Whether the keychain holds a key for the hosted provider. The key itself is read only when a summary runs.
    public var keyStored: Bool
    /// Command that starts an ACP agent, run through a login shell, and its working directory.
    public var agentCommand: String
    public var agentDirectory: String

    public init(enabled: Bool = false, service: SummaryService = .local, localEndpoint: String = "http://127.0.0.1:1234/v1",
                localModel: String = "", contextTokens: Int = 32768, reasoningDisabled: Bool = false,
                hostedModel: String = "", keyStored: Bool = false, agentCommand: String = "claude-agent-acp", agentDirectory: String = "~") {
        self.enabled = enabled; self.service = service; self.localEndpoint = localEndpoint; self.localModel = localModel
        self.contextTokens = contextTokens; self.reasoningDisabled = reasoningDisabled; self.hostedModel = hostedModel
        self.keyStored = keyStored; self.agentCommand = agentCommand; self.agentDirectory = agentDirectory
    }
}

/// Why a summary cannot run with the current configuration. Thrown by `Summarizer.summarize`
/// when it is called anyway.
public enum SummaryUnavailability: LocalizedError, Equatable, Sendable {
    /// The summary is turned off in the settings.
    case disabled
    /// The local server address is not a loopback HTTP URL, or no model is given.
    case localServerNotConfigured
    case apiKeyMissing(SummaryService)
    case modelMissing(SummaryService)
    case agentCommandMissing

    public var errorDescription: String? {
        switch self {
        case .disabled: String(localized: "Activez un modèle dans les réglages pour générer une synthèse.", bundle: .hwyd)
        case .localServerNotConfigured: SummaryFailure.invalidEndpoint.errorDescription
        case .apiKeyMissing(let service): SummaryFailure.apiKeyMissing(service.displayName).errorDescription
        case .modelMissing(let service): SummaryFailure.modelMissing(service.displayName).errorDescription
        case .agentCommandMissing: AgentSummaryFailure.commandMissing.errorDescription
        }
    }
}

/// A summarizer is `ready` or `unavailable`; the app combines it with the work coordinator, which
/// adds `busy` while other heavy work runs (`Availability.combined(with:)`).
public typealias SummaryAvailability = Availability<SummaryUnavailability>

/// What the summary tab tells the user about a summarizer: where the draft is written and what
/// leaves the Mac. Each implementation states its own; views only display it.
public struct SummaryDisclosure: Equatable, Sendable {
    /// One line under the summary controls.
    public let label: String
    /// Explanation shown before the first summary of a session.
    public let detail: String
    public init(label: String, detail: String) { self.label = label; self.detail = detail }
}

/// Writes the summary of a recording. Each implementation decides from its own configuration
/// whether it can run; callers ask `availability` to explain, and only ever call `summarize`.
public protocol Summarizer: Sendable {
    var availability: SummaryAvailability { get }
    /// Where the draft is written and what leaves the Mac, in the user's language.
    var disclosure: SummaryDisclosure { get }
    /// Summarizes the recording as it is given. Throws `SummaryUnavailability` when not ready,
    /// and `CancellationError` (or a cancelled `URLError`) when the task is cancelled.
    func summarize(_ recording: Recording, progress: @escaping @Sendable (SummaryProgress) async -> Void) async throws -> SummaryProvenance
}

extension Summarizer {
    func requireReady() throws {
        if case .unavailable(let reason) = availability { throw reason }
    }
}

/// What the summarizers need from the host, beyond the configuration.
public struct SummarizerEnvironment: Sendable {
    /// The HWYD data directory: store for the agent, resumable checkpoints under `cache/summaries`.
    public var dataDirectory: URL
    /// The `hwyd-mcp` helper handed to an ACP agent.
    public var mcpExecutable: URL
    /// Reads the API key of a hosted provider. Called only when a summary runs.
    public var apiKey: @Sendable (SummaryService) throws -> String?

    public init(dataDirectory: URL, mcpExecutable: URL, apiKey: @escaping @Sendable (SummaryService) throws -> String?) {
        self.dataDirectory = dataDirectory; self.mcpExecutable = mcpExecutable; self.apiKey = apiKey
    }

    func cacheDirectory(for recording: Recording) -> URL {
        dataDirectory.appendingPathComponent("cache/summaries/" + recording.id.uuidString)
    }
}

/// Chooses the summarizer for a configuration. The only place that knows which implementation serves which setting.
public enum SummarizerFactory {
    public static func make(_ configuration: SummaryConfiguration, environment: SummarizerEnvironment) -> any Summarizer {
        guard configuration.enabled else { return UnavailableSummarizer(reason: .disabled) }
        switch configuration.service {
        case .local:
            return LocalSummarizer(endpoint: configuration.localEndpoint, model: configuration.localModel,
                                   contextTokens: configuration.contextTokens, reasoningDisabled: configuration.reasoningDisabled,
                                   environment: environment)
        case .agent:
            return AgentSummarizer(command: configuration.agentCommand, directory: configuration.agentDirectory, environment: environment)
        case .mistral, .openai, .anthropic, .gemini:
            return HostedSummarizer(service: configuration.service, model: configuration.hostedModel,
                                    keyStored: configuration.keyStored, environment: environment)
        }
    }
}

/// Null object for a summary that cannot run at all, such as when the feature is off.
public struct UnavailableSummarizer: Summarizer {
    public let reason: SummaryUnavailability
    public init(reason: SummaryUnavailability) { self.reason = reason }
    public var availability: SummaryAvailability { .unavailable(reason) }
    /// No provider is chosen: the line claims no location, the detail says what is missing.
    public var disclosure: SummaryDisclosure {
        SummaryDisclosure(label: String(localized: "Brouillon à relire", bundle: .hwyd), detail: reason.localizedDescription)
    }
    public func summarize(_ recording: Recording, progress: @escaping @Sendable (SummaryProgress) async -> Void) async throws -> SummaryProvenance {
        throw reason
    }
}

/// OpenAI-compatible server on this Mac (LM Studio, Ollama), through the resumable pipeline.
public struct LocalSummarizer: Summarizer {
    public let endpoint: String
    public let model: String
    public let contextTokens: Int
    public let reasoningDisabled: Bool
    let environment: SummarizerEnvironment

    public init(endpoint: String, model: String, contextTokens: Int, reasoningDisabled: Bool, environment: SummarizerEnvironment) {
        self.endpoint = endpoint; self.model = model; self.contextTokens = contextTokens
        self.reasoningDisabled = reasoningDisabled; self.environment = environment
    }

    private var url: URL? {
        guard let url = URL(string: endpoint), LocalLLMProvider.isLocal(url),
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return url
    }
    public var availability: SummaryAvailability { url == nil ? .unavailable(.localServerNotConfigured) : .ready }
    public var disclosure: SummaryDisclosure {
        SummaryDisclosure(label: String(localized: "Brouillon local, à relire", bundle: .hwyd),
                          detail: String(localized: "Lancez la génération avec votre modèle local. Vos notes et votre transcript restent indépendants.", bundle: .hwyd))
    }
    /// Characters per request: the loaded context minus room for instructions and output, two characters per token.
    var inputCharacterLimit: Int { max(12_000, (contextTokens - 10_000) * 2) }

    public func summarize(_ recording: Recording, progress: @escaping @Sendable (SummaryProgress) async -> Void) async throws -> SummaryProvenance {
        guard let url else { throw SummaryUnavailability.localServerNotConfigured }
        let provider = try LocalLLMProvider(endpoint: url, model: model, reasoningEffort: reasoningDisabled ? "none" : nil)
        return try await SummaryPipeline.run(recording, provider: provider, model: model,
            inputCharacterLimit: inputCharacterLimit,
            cacheDirectory: environment.cacheDirectory(for: recording), reuseCache: recording.summary == nil,
            providerIdentity: url.absoluteString + "|reasoning=" + (reasoningDisabled ? "none" : "server-default"),
            progress: progress)
    }
}

/// Hosted provider (Mistral, OpenAI, Anthropic, Gemini). The transcript leaves the Mac; the key is
/// read from the environment only when a summary runs.
public struct HostedSummarizer: Summarizer {
    public let service: SummaryService
    public let model: String
    public let keyStored: Bool
    let environment: SummarizerEnvironment

    public init(service: SummaryService, model: String, keyStored: Bool, environment: SummarizerEnvironment) {
        self.service = service; self.model = model; self.keyStored = keyStored; self.environment = environment
    }

    public var availability: SummaryAvailability {
        if !service.isRemote { return .unavailable(.localServerNotConfigured) }
        if !keyStored { return .unavailable(.apiKeyMissing(service)) }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .unavailable(.modelMissing(service)) }
        return .ready
    }
    /// The transcript is sent to the provider: both lines name it.
    public var disclosure: SummaryDisclosure {
        SummaryDisclosure(label: String(localized: "Brouillon rédigé par \(service.displayName), à relire", bundle: .hwyd),
                          detail: String(localized: "Le transcript sera envoyé à \(service.displayName). Vos notes restent sur ce Mac.", bundle: .hwyd))
    }

    public func summarize(_ recording: Recording, progress: @escaping @Sendable (SummaryProgress) async -> Void) async throws -> SummaryProvenance {
        try requireReady()
        guard let key = try environment.apiKey(service), !key.isEmpty else { throw SummaryUnavailability.apiKeyMissing(service) }
        let provider = try RemoteLLMProvider(service: service, model: model, apiKey: key)
        return try await SummaryPipeline.run(recording, provider: provider, model: provider.model,
            inputCharacterLimit: provider.requestCharacterCeiling,
            cacheDirectory: environment.cacheDirectory(for: recording), reuseCache: recording.summary == nil,
            providerIdentity: provider.identity, progress: progress)
    }
}

/// ACP agent (Claude Code, Codex…) started in a working directory, with a restricted `hwyd-mcp`.
public struct AgentSummarizer: Summarizer {
    public let command: String
    public let directory: String
    let environment: SummarizerEnvironment

    public init(command: String, directory: String, environment: SummarizerEnvironment) {
        self.command = command; self.directory = directory; self.environment = environment
    }

    public var availability: SummaryAvailability {
        command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .unavailable(.agentCommandMissing) : .ready
    }
    public var disclosure: SummaryDisclosure {
        SummaryDisclosure(label: String(localized: "Brouillon de votre agent, à relire", bundle: .hwyd),
                          detail: String(localized: "Votre agent ACP rédigera la synthèse à partir du transcript et de son propre contexte. Vos notes restent sur ce Mac.", bundle: .hwyd))
    }
    var workingDirectory: URL { URL(fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true) }

    public func summarize(_ recording: Recording, progress: @escaping @Sendable (SummaryProgress) async -> Void) async throws -> SummaryProvenance {
        try requireReady()
        return try await ACPSummaryAgent.run(recording, command: command, workingDirectory: workingDirectory,
            mcpExecutable: environment.mcpExecutable, storeDirectory: environment.dataDirectory, progress: progress)
    }
}
