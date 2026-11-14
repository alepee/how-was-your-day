import AppKit
import Foundation
import HWYDCore

/// The process-wide objects, built once from the launch mode read at start. Nothing else reads
/// the command line.
@MainActor enum AppRoot {
    static let mode = LaunchMode(arguments: CommandLine.arguments)
    static let model = AppModel(environment: .launch(mode))
    static let updater = AppUpdater()
}

/// What records into a set of sessions and what processes them. The root makes the capture for
/// each start from it; the examples get a simulation.
struct CaptureSource {
    /// Simulated audio: never transcribed, the session is an example.
    let isSimulated: Bool
    let make: @MainActor () throws -> any AudioCapture

    /// Core Audio, writing into the store's folder. Only the installed app's own data uses it.
    static func coreAudio(directory: URL) -> CaptureSource { CaptureSource(isSimulated: false) { CoreAudioCapture(directory: directory) } }
    static func simulated(_ make: @escaping @MainActor () -> any AudioCapture = { SimulatedCapture() }) -> CaptureSource {
        CaptureSource(isSimulated: true, make: make)
    }
    /// Refuses every start with the reason: no store, or a model that must never open the microphone.
    static func unavailable(_ reason: String) -> CaptureSource {
        CaptureSource(isSimulated: false) { throw CaptureFailure(message: reason) }
    }
}

/// One set of sessions with the adapters that serve it: the user's own sessions, or the examples.
/// The model shows one workspace at a time and holds no mode flag: what differs between the two
/// lives in these adapters.
@MainActor struct Workspace {
    var library: SessionLibrary
    /// The store under the library: people, integration settings, audio files. Nil for the
    /// examples, previews, and when the store cannot be opened.
    var store: SessionStore?
    var capture: CaptureSource
    var transcription: any TranscriptionService
    var voiceMemory: any VoiceMemory
    var speechModels: any SpeechModelCatalog
    /// The summarizer for the current summary settings.
    var summarizer: @MainActor (SummaryConfiguration) -> any Summarizer
    /// Where preference changes go while this workspace shows.
    var settings: SettingsStore
    /// Presentation only: the banner, the « Simulation » labels, and summary settings that are
    /// neither saved nor checked against the keychain or the network.
    var isExamples = false

    /// The examples: fictional sessions in memory, a simulated capture, services that refuse
    /// with `WorkRefusal.examples`, preferences read and never written. The summary tab still
    /// shows the configured summarizer.
    static func examples(_ recordings: [Recording] = DemoContent.recordings(), over preferences: SettingsStore, capture: CaptureSource = .simulated(),
                         summarizer: @escaping @MainActor (SummaryConfiguration) -> any Summarizer) -> Workspace {
        Workspace(library: SessionLibrary(volatile: recordings), store: nil, capture: capture,
                  transcription: ExamplePipeline(), voiceMemory: ExamplePipeline(), speechModels: ExamplePipeline(),
                  summarizer: { RefusingSummarizer(showing: summarizer($0)) },
                  settings: VolatileSettings(over: preferences), isExamples: true)
    }
}

/// The composition root of one `AppModel`: every adapter it uses, chosen once. `launch(_:)`
/// builds it for the running process; previews, snapshots and synthetic checks build theirs with
/// doubles, and never the user's preferences, keychain, microphone or data.
@MainActor struct AppEnvironment {
    var dataDirectory: URL
    /// Preferences read at start, and where the recording shortcut is saved.
    var preferences: SettingsStore
    var helpers: HelperLocator
    /// Shows notices as toasts in the window.
    var toasts = ToastCenter()
    /// Where flows report; the toasts unless a check records the notices.
    var notifier: (any UserNotifier)?
    var coordinator = WorkCoordinator()
    var agentDiscovery: any AgentDiscovery = FixedAgentDiscovery()
    /// The installed app: keychain, calendar. Off for previews and checks.
    var usesSystem = false
    var appliesAppearance = false
    /// Monotonic time of the capture clock, in seconds.
    var clock: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The user's sessions, or what stands for them.
    var user: Workspace
    /// Whether the window opens on the examples.
    var startsWithExamples = false
    /// Said to the user once the model exists.
    var startupError: String?
    /// Languages shown before the catalog answers; previews only, which never ask it.
    var initialLocales: SpeechLocales?
    /// What records while the examples show.
    var exampleCapture: CaptureSource = .simulated()
    /// The example sessions; snapshots add or leave out some.
    var exampleRecordings: @MainActor () -> [Recording] = { DemoContent.recordings() }

    /// The examples the user can open from the settings, over these preferences.
    func examples() -> Workspace { Workspace.examples(exampleRecordings(), over: preferences, capture: exampleCapture, summarizer: user.summarizer) }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HWYD")
    }

    /// The process's model. Synthetic modes get a preview: their checks build their own models.
    static func launch(_ mode: LaunchMode) -> AppEnvironment {
        if case .app(let examples) = mode { return installed(examples: examples) }
        return preview()
    }

    /// The installed app on the user's data. `examples` opens it on the examples (`--demo`); the
    /// user can leave them for their own sessions.
    static func installed(examples: Bool) -> AppEnvironment {
        let directory = applicationSupport, preferences = UserDefaultsSettings(), helpers = HelperLocator.app
        let summarizer = summarizers(directory: directory, helpers: helpers, readsKeychain: true)
        var user = Workspace(library: SessionLibrary(volatile: []), store: nil, capture: .unavailable(WorkRefusal.storeUnavailable.localizedDescription),
                             transcription: HelperTranscriptionService(helpers: helpers, store: directory),
                             voiceMemory: HelperVoiceMemory(helpers: helpers, store: directory),
                             speechModels: HelperSpeechModelCatalog(helpers: helpers, store: directory),
                             summarizer: summarizer, settings: preferences)
        var startupError: String?
        do {
            let store = try SessionStore(directory: directory)
            user.store = store; user.library = library(over: store, sweepsFiles: true); user.capture = .coreAudio(directory: directory)
        } catch { startupError = String(localized: "Impossible d’ouvrir les données locales : \(error.localizedDescription)") }
        return AppEnvironment(dataDirectory: directory, preferences: preferences, helpers: helpers, agentDiscovery: LoginShellAgentDiscovery(),
                              usesSystem: true, appliesAppearance: true, user: user, startsWithExamples: examples, startupError: startupError)
    }

    /// Volatile sessions for previews and snapshots: the examples (default), or `recordings` shown
    /// as the user's own. Nothing is saved; the capture is simulated; no helper runs.
    static func preview(recordings: [Recording]? = nil, examples: [Recording]? = nil, preferences: SettingsStore = InMemorySettings(),
                        capture: CaptureSource = .simulated(), coordinator: WorkCoordinator = WorkCoordinator(),
                        clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> AppEnvironment {
        let summarizer = summarizers(directory: applicationSupport, helpers: .app, readsKeychain: false)
        let user = Workspace(library: SessionLibrary(volatile: recordings ?? []), store: nil, capture: capture,
                             transcription: ExamplePipeline(), voiceMemory: ExamplePipeline(), speechModels: ExamplePipeline(),
                             summarizer: summarizer, settings: preferences)
        return AppEnvironment(dataDirectory: applicationSupport, preferences: preferences, helpers: .app, coordinator: coordinator,
                                         appliesAppearance: true, clock: clock, user: user, startsWithExamples: recordings == nil,
                                         initialLocales: SpeechLocales(installed: ["fr-FR", "en-US"], supported: ["de-DE", "en-US", "es-ES", "fr-FR"]),
                                         exampleCapture: capture, exampleRecordings: { examples ?? DemoContent.recordings() })
    }

    /// A store in `directory` for the synthetic checks (`--ui-test`, `--asr-test`). The pipeline is
    /// the bundled helper on that store unless a double is given; preferences are in memory unless
    /// a check gives its own; the microphone is never opened and the keychain never read.
    static func synthetic(directory: URL, preferences: SettingsStore = InMemorySettings(), notifier: (any UserNotifier)? = nil,
                          transcription: (any TranscriptionService)? = nil, voiceMemory: (any VoiceMemory)? = nil,
                          speechModels: (any SpeechModelCatalog)? = nil,
                          summarizer: (@MainActor (SummaryConfiguration) -> any Summarizer)? = nil,
                          coordinator: WorkCoordinator = WorkCoordinator()) throws -> AppEnvironment {
        let helpers = HelperLocator.app
        let store = try SessionStore(directory: directory)
        // A check sweeps the folder it was given, never the user's data folder.
        let ownsFolder = directory.standardizedFileURL.resolvingSymlinksInPath() != applicationSupport.standardizedFileURL.resolvingSymlinksInPath()
        let user = Workspace(library: library(over: store, sweepsFiles: ownsFolder), store: store,
                             capture: .unavailable("This model never opens the microphone."), // l10n:ignore
                             transcription: transcription ?? HelperTranscriptionService(helpers: helpers, store: directory),
                             voiceMemory: voiceMemory ?? HelperVoiceMemory(helpers: helpers, store: directory),
                             speechModels: speechModels ?? HelperSpeechModelCatalog(helpers: helpers, store: directory),
                             summarizer: summarizer ?? summarizers(directory: directory, helpers: helpers, readsKeychain: false),
                             settings: preferences)
        return AppEnvironment(dataDirectory: directory, preferences: preferences, helpers: helpers, notifier: notifier,
                              coordinator: coordinator, user: user)
    }

    /// `sweepsFiles`: whether each load removes the files of sessions deleted earlier from the store's folder.
    private static func library(over store: SessionStore, sweepsFiles: Bool) -> SessionLibrary {
        // Asked at each publication, so a folder chosen later applies at once.
        SessionLibrary(repository: store, exportTarget: { try await store.exportDirectory().map(FolderExportPublisher.init) }, sweepsFiles: sweepsFiles)
    }

    /// Summarizers for the settings of the moment. Only the installed app reads keys from the keychain.
    private static func summarizers(directory: URL, helpers: HelperLocator, readsKeychain: Bool) -> @MainActor (SummaryConfiguration) -> any Summarizer {
        let environment = SummarizerEnvironment(dataDirectory: directory, mcpExecutable: helpers.mcp) { service in
            readsKeychain ? try SummaryKeychain.key(for: service) : nil
        }
        return { SummarizerFactory.make($0, environment: environment) }
    }
}

extension UserNotice {
    /// A request that was not taken, with its reason.
    static func refusal(_ refusal: WorkRefusal) -> UserNotice { .info(refusal.localizedDescription) }

    /// What the user is told after a voice memory request; nil when the screen shows it already.
    static func voice(_ outcome: VoiceOutcome) -> UserNotice? {
        switch outcome {
        case .enrolled(let name, let proposed):
            let found = proposed == 0 ? nil : proposed == 1 ? String(localized: "Une autre voix ressemble à une personne connue, à confirmer.")
                : String(localized: "\(proposed) autres voix ressemblent à des personnes connues, à confirmer.")
            return .info([String(localized: "Voix de \(name) mémorisée."), found].compactMap { $0 }.joined(separator: " "))
        case .enrolledSessionChanged(let name): return .info(String(localized: "Voix de \(name) mémorisée."))
        case .identified(let proposed): return .info(String(localized: "\(proposed) correspondance(s) proposée(s), à confirmer."))
        case .identificationSessionChanged: return .info(String(localized: "La session a changé pendant la reconnaissance. Aucune proposition appliquée."))
        case .sourcesRead: return nil
        case .forgotten(let name): return .info(String(localized: "Empreinte de \(name) effacée. Sa voix ne sera plus reconnue avant une nouvelle mémorisation."))
        case .opposed(let name): return .info(String(localized: "Empreintes de \(name) supprimées. Opposition enregistrée."))
        case .contributionWithdrawn(let name): return .info(String(localized: "Apport retiré de l’empreinte de \(name)."))
        case .oppositionLifted(let name): return .info(String(localized: "\(name) n’est plus exclue. Mémorisez sa voix depuis une session pour la reconnaître à nouveau."))
        }
    }

    /// Why a voice cannot be memorized under this name.
    static func enrollmentRefused(_ refusal: EnrollmentRefusal) -> UserNotice {
        switch refusal {
        case .invalidName: .error(String(localized: "Le nom doit contenir entre 1 et 120 caractères."))
        case .opposed(let person): .error(String(localized: "\(person.name) est exclue de la reconnaissance. Levez l’exclusion dans Réglages › Audio et voix."))
        }
    }
}
