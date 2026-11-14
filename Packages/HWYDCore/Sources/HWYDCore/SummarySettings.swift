import Combine
import Foundation

/// The summary settings shown in the app, their persistence, the hosted provider's key and model
/// list, and the detected ACP agents. Produces the `SummaryConfiguration` a summarizer is made from.
@MainActor public final class SummarySettings: ObservableObject {
    @Published public var enabled: Bool
    /// OpenAI-compatible server on this Mac.
    @Published public var endpoint: String
    @Published public var localModel: String
    @Published public var contextTokens: Int
    @Published public var reasoningDisabled: Bool
    /// Choosing a hosted provider and storing its key is the opt-in: nothing is sent before both.
    @Published public private(set) var service: SummaryService
    /// Model of the hosted provider selected by `service`; empty for the others.
    @Published public var hostedModel = ""
    @Published public private(set) var keyStored = false
    /// Models offered by the provider for the stored key; empty until fetched.
    @Published public private(set) var availableModels: [String] = []
    @Published public private(set) var modelsLoading = false
    /// Agent mode: the command that starts an ACP agent, run through a login shell, and its working directory.
    @Published public var agentCommand: String
    @Published public var agentDirectory: String
    /// Commands of the known ACP agents installed on this Mac.
    @Published public private(set) var detectedAgents: [String] = []
    /// Demo mode: nothing is saved, no key is touched, no request or process starts.
    public var isDemo = false
    /// Tells the user about key and model list failures.
    private let notifier: any UserNotifier

    private let store: SettingsStore
    /// False for previews and tests: preferences stay untouched, and neither the stored keys nor the network are used.
    private let usesSystem: Bool
    private let discovery: any AgentDiscovery
    /// Hosted providers' keys, in the vault the composition root gives: the keychain for the
    /// installed app, memory for everything else.
    private let keys: SummaryKeys
    private var modelsTask: Task<Void, Never>?

    public init(store: SettingsStore, usesSystem: Bool, notifier: any UserNotifier, discovery: any AgentDiscovery = FixedAgentDiscovery(),
                secrets: any SecretVault = InMemorySecretVault()) {
        self.store = store; self.usesSystem = usesSystem; self.notifier = notifier; self.discovery = discovery
        keys = SummaryKeys(vault: secrets)
        enabled = store.value(.summaryEnabled)
        endpoint = store.value(.summaryEndpoint)
        localModel = store.value(.summaryLocalModel)
        let tokens = store.value(.summaryContextTokens)
        contextTokens = tokens == 0 ? SettingKey<Int>.summaryContextTokens.defaultValue : tokens
        reasoningDisabled = store.value(.summaryReasoningDisabled)
        service = store.value(.summaryService)
        agentCommand = store.value(.summaryAgentCommand)
        agentDirectory = store.value(.summaryAgentDirectory)
        loadHostedSettings()
    }

    /// Every summary setting as one value, read by the summarizer.
    public var configuration: SummaryConfiguration {
        SummaryConfiguration(enabled: enabled, service: service, localEndpoint: endpoint, localModel: localModel,
                             contextTokens: contextTokens, reasoningDisabled: reasoningDisabled, hostedModel: hostedModel,
                             keyStored: keyStored, agentCommand: agentCommand, agentDirectory: agentDirectory)
    }

    public func save() {
        guard !isDemo, usesSystem else { return }
        store.set(enabled, for: .summaryEnabled)
        store.set(endpoint, for: .summaryEndpoint)
        store.set(localModel, for: .summaryLocalModel)
        store.set(contextTokens, for: .summaryContextTokens)
        store.set(reasoningDisabled, for: .summaryReasoningDisabled)
        store.set(service, for: .summaryService)
        store.set(agentCommand, for: .summaryAgentCommand)
        store.set(agentDirectory, for: .summaryAgentDirectory)
        if service.isRemote { store.set(hostedModel, for: .summaryHostedModel(service)) }
    }

    private func loadHostedSettings() {
        hostedModel = service.isRemote ? store.value(.summaryHostedModel(service)) ?? service.defaultModel : ""
        modelsTask?.cancel(); modelsTask = nil
        availableModels = []; modelsLoading = false
        keyStored = service.isRemote && usesSystem && keys.hasKey(for: service)
    }

    public func select(_ newService: SummaryService) {
        guard newService != service else { return }
        save()
        service = newService
        loadHostedSettings()
        save()
    }

    /// Checks the key by listing the provider's models, then stores it. A rejected key is not stored;
    /// a network failure still stores it, since the check can be repeated later.
    public func saveKey(_ key: String) {
        let service = service
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard service.isRemote, !isDemo, usesSystem, !key.isEmpty else { return }
        modelsTask?.cancel()
        modelsLoading = true
        modelsTask = Task {
            defer { if self.service == service { modelsLoading = false } }
            var models: [String] = []
            do { models = try await SummaryModelCatalog.models(service: service, apiKey: key) }
            catch SummaryFailure.remoteRejected(let name, let status, let detail) where status == 401 || status == 403 {
                notifier.notify(.error(SummaryFailure.remoteRejected(service: name, status: status, detail: detail).localizedDescription + " "
                                       + String(localized: "La clé n’a pas été enregistrée.", bundle: .hwyd)))
                return
            } catch {
                if Task.isCancelled { return }
                notifier.notify(.info(String(localized: "Liste des modèles indisponible : \(error.localizedDescription)", bundle: .hwyd)))
            }
            guard !Task.isCancelled else { return }
            do { try keys.setKey(key, for: service) }
            catch { notifier.notify(.error(String(localized: "Clé API : \(error.localizedDescription)", bundle: .hwyd))); return }
            guard self.service == service else { return }
            keyStored = true
            applyAvailableModels(models)
        }
    }

    /// Fetches the provider's models for the stored key. Called when the settings show a hosted provider.
    public func refreshModels() {
        let service = service
        guard service.isRemote, keyStored, !isDemo, usesSystem, !modelsLoading else { return }
        modelsLoading = true
        modelsTask = Task {
            defer { if self.service == service { modelsLoading = false } }
            do {
                guard let key = try keys.key(for: service) else { return }
                let models = try await SummaryModelCatalog.models(service: service, apiKey: key)
                if !Task.isCancelled, self.service == service { applyAvailableModels(models) }
            } catch {
                if !Task.isCancelled, self.service == service {
                    notifier.notify(.error(String(localized: "Modèles \(service.displayName) : \(error.localizedDescription)", bundle: .hwyd)))
                }
            }
        }
    }

    func applyAvailableModels(_ models: [String]) {
        availableModels = models
        // A suggested default this account does not offer is cleared so the user picks from the list.
        // A model the user typed or chose is never replaced.
        if !models.isEmpty, hostedModel == service.defaultModel, !models.contains(hostedModel) {
            hostedModel = ""
            save()
        }
    }

    public func removeKey() {
        guard service.isRemote, !isDemo, usesSystem else { return }
        modelsTask?.cancel(); availableModels = []; modelsLoading = false
        do {
            try keys.removeKey(for: service); keyStored = false
            notifier.notify(.info(String(localized: "Clé \(service.displayName) supprimée.", bundle: .hwyd)))
        } catch { notifier.notify(.error(String(localized: "Clé API : \(error.localizedDescription)", bundle: .hwyd))) }
    }

    /// Looks for the known ACP agents, once. Previews and tests inject a discovery that starts no process.
    public func detectAgents() {
        guard !isDemo, detectedAgents.isEmpty else { return }
        let discovery = discovery
        Task { detectedAgents = await discovery.installedAgents() }
    }
}
