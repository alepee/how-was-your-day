import AppKit
import AVFoundation
import Combine
import Foundation
import HWYDCore

@MainActor
final class AppModel: ObservableObject {
    /// The adapters this model was built with, chosen once by the composition root.
    private let environment: AppEnvironment
    /// The sessions shown and the adapters that serve them: the user's, or the examples.
    /// The model checks no mode: refusals, persistence and capture are the workspace's adapters'.
    @Published private(set) var workspace: Workspace
    /// The sessions shown. Its edits, saves, merges with other writers and stale checks are its own.
    var sessionLibrary: SessionLibrary { workspace.library }
    /// What the library shows, pending edits included.
    var recordings: [Recording] { sessionLibrary.recordings }
    @Published var selectedID: UUID?
    @Published var search = ""
    @Published var kindFilter: SessionKind?
    @Published var activeTab: DetailTab = .transcript
    @Published var showSettings = false { didSet { if showSettings { showNewSession = false } } }
    @Published var settingsCategory: SettingsCategory = .general
    /// Shows what the notifier reports as toasts. Observed by the toast stack, not through this model.
    let toastCenter: ToastCenter
    /// Where flows report errors and notices; the toast center in the app.
    let notifier: any UserNotifier
    /// The setup screen shown before a capture starts: kind and optional name.
    @Published var showNewSession = false
    @Published var newSessionKind: SessionKind = .adHoc {
        didSet { workspace.settings.set(newSessionKind, for: .newSessionKind) }
    }
    @Published var newSessionTitle = ""
    /// The examples show: banner and « Simulation » labels. Presentation only.
    var isDemoMode: Bool { workspace.isExamples }
    /// The library has not finished its first load.
    var isLoading: Bool { !sessionLibrary.isReady }
    /// Runs the capture: its clock, pause, end and what follows it. The properties below show its state.
    private(set) lazy var captureSession = CaptureSession(notifier: notifier, transcribe: { [weak self] id in
        await self?.enqueued { [weak self] in await self?.requestTranscription(id) ?? .refused(.unavailable("")) } ?? .refused(.unavailable(""))
    }, now: environment.clock)
    @Published private(set) var activeCaptureID: UUID? { didSet { updateBusy() } }
    @Published private(set) var elapsed: Double = 0
    /// The active capture is paused: no audio is captured and the clock is frozen.
    @Published private(set) var isCapturePaused = false
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published var isStarting = false
    private var shownCapturePhase: CapturePhase = .idle
    private var captureChanges: [AnyCancellable] = []
    /// Moves the session clock shown while a capture runs.
    private var captureClock: Timer?
    /// Playback ticks live outside `objectWillChange`: only views reading them are invalidated.
    let playback = PlaybackState()
    var isPlaying: Bool { get { playback.isPlaying } set { playback.isPlaying = newValue } }
    var playbackTime: Double { get { playback.time } set { playback.time = newValue } }
    @Published var mutedTracks: Set<AudioSource> = []
    @Published var soloTracks: Set<AudioSource> = []
    @Published var trackEnvelopes: [AudioSource: TrackEnvelope] = [:]
    @Published var waveformLoading = false
    @Published var waveformError: String?
    private let waveformReader = WaveformReader()
    @Published var editingSpeakerID: UUID?
    @Published var speakerName = ""
    @Published var deleteCandidate: Recording?
    @Published var mcpWritesEnabled = false
    @Published var exportDirectory = ""
    @Published var people: [VoicePerson] = []
    /// Confirmed voice waiting for the user to confirm its enrollment.
    @Published var enrollmentCandidateID: UUID?
    /// What each session added to a person's voice print, loaded on demand in the settings.
    @Published var voiceContributions: [UUID: [VoiceContribution]] = [:]
    /// Voice prints of known people, served by the pipeline helper in the app.
    var voiceMemory: any VoiceMemory { workspace.voiceMemory }
    /// Provider, model, key and agent settings of the summary. Its changes are republished by this model.
    let summarySettings: SummarySettings
    private var summarySettingsChanges: AnyCancellable?
    /// Requests a session's summary once it is ready, when the user turned it on. Only for the
    /// stored library: previews, demo mode and snapshots have none.
    private(set) var automaticSummary: AutomaticSummaryTrigger?
    private var automaticSummarySetting: AnyCancellable?
    /// Sessions whose automatic summary waits or runs.
    private var automaticSummaryJobs: Set<UUID> = []
    @Published var summaryProgress: SummaryProgress?
    @Published var diarizationEnabled = false {
        didSet { workspace.settings.set(diarizationEnabled, for: .diarizationEnabled) }
    }
    /// Transcribes sessions: the pipeline helper, a double, or the examples' refusal.
    var transcription: any TranscriptionService { workspace.transcription }
    /// Installed and installable speech languages and voice models.
    var speechModels: any SpeechModelCatalog { workspace.speechModels }
    /// Runs transcription, voice jobs, model installs and summaries one at a time. The model
    /// requests work and shows the coordinator's state; it keeps no busy flag of its own.
    let coordinator: WorkCoordinator
    /// The coordinator's latest state, as the views show it.
    @Published private(set) var work = WorkSnapshot()
    /// A capture or some heavy work is in progress: the updater waits. Changes only when that
    /// answer flips.
    @Published private(set) var isBusy = false
    private var workBusy = false { didSet { updateBusy() } }
    /// Triggers run their request in the order they were made: a cancel never overtakes the
    /// request it cancels, and `idle()` knows when every request so far is decided.
    private var requestChain: Task<Void, Never>?
    private var pendingRequests = 0
    /// Session whose language should be chosen again, from a detection notice.
    @Published var languageChoiceID: UUID?
    /// System-wide shortcut that starts or ends a recording. Nil when the user cleared it.
    @Published var recordingShortcut: RecordingShortcut? = .standard {
        didSet {
            guard oldValue != recordingShortcut else { return }
            // Empty data records that the user cleared the shortcut.
            // System-wide, so saved even while the examples show.
            preferences.set(recordingShortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), for: .recordingShortcut)
            registerRecordingShortcut()
        }
    }
    /// The shortcut is taken by another application or the system.
    @Published var recordingShortcutUnavailable = false
    /// Off for previews and test runs, which must not take a system-wide shortcut.
    private var shortcutEnabled = false
    func enableRecordingShortcut() { shortcutEnabled = true; registerRecordingShortcut() }
    func reloadRecordingShortcut() { registerRecordingShortcut() }
    private func registerRecordingShortcut() {
        guard shortcutEnabled else { return }
        recordingShortcutUnavailable = !GlobalHotKey.shared.register(recordingShortcut) { [weak self] in self?.toggleRecordingFromShortcut() }
    }
    /// Starts a session with the last chosen kind and the default language, or ends the running one.
    /// The window stays where it is: the shortcut is meant to be used from another application.
    func toggleRecordingFromShortcut() {
        if activeCaptureID != nil { stopCapture(reveal: false) }
        else if !isStarting { startCapture(kind: newSessionKind, reveal: false) }
    }
    /// Language chosen on the setup screen for the next session.
    @Published var newSessionLanguage = SpeechLanguage.automatic
    /// One locale per language, as reported by Apple Speech on this Mac.
    @Published var installedSpeechLocales: [String] = []
    @Published var supportedSpeechLocales: [String] = []
    /// Languages offered for a session: automatic detection, then the installed languages.
    var sessionLanguageChoices: [String] { [SpeechLanguage.automatic] + installedSpeechLocales }
    /// Reads the installed languages and the voice models again.
    func refreshSpeechLanguages() {
        let speechModels = speechModels
        guard speechModels.refusal == nil else { return }
        Task {
            diarizerReady = await speechModels.diarizerReady()
            if let locales = try? await speechModels.locales() { showSpeechLocales(locales) }
        }
    }
    private func showSpeechLocales(_ locales: SpeechLocales) {
        installedSpeechLocales = SpeechLanguage.oneLocalePerLanguage(locales.installed)
        supportedSpeechLocales = SpeechLanguage.oneLocalePerLanguage(locales.supported)
            .sorted { SpeechLanguage.displayName($0).localizedCompare(SpeechLanguage.displayName($1)) == .orderedAscending }
    }
    /// Opens the session and its reprocessing choices, wherever the user is.
    func chooseLanguage(for id: UUID) {
        guard recordings.contains(where: { $0.id == id }) else { return }
        showSettings = false; showNewSession = false; selectedID = id; activeTab = .transcript
        languageChoiceID = id; showWindow?()
    }
    /// Offers to install a language detection recognized, or to choose one when nothing fits.
    private func reportLanguageFindings(_ detections: [LanguageDetection], id: UUID) {
        let label = { (source: AudioSource) in source == .mic ? String(localized: "la piste Micro") : String(localized: "la piste Système") }
        if let suggestion = detections.first(where: { $0.suggestedLocale != nil }), let locale = suggestion.suggestedLocale {
            let other = SpeechLanguage.confusable[SpeechLanguage.languageCode(of: locale)]
            let name = SpeechLanguage.displayName(locale) + (other.map { String(localized: " (ou \(SpeechLanguage.displayName($0)))") } ?? "")
            notifier.notify(.info(String(localized: "La langue de \(label(suggestion.source)) semble être : \(name). Ce modèle n’est pas installé."), actions: [
                .perform(String(localized: "Installer et retranscrire")) { [weak self] in self?.installSpeechModel(locale) { [weak self] in self?.transcribe(id, language: SpeechLanguage.automatic) } },
                .navigate(String(localized: "Choisir la langue"), to: .languageChoice(id))], sticky: true))
        } else if let unknown = detections.first(where: { $0.unrecognized == true }) {
            notifier.notify(.info(String(localized: "La langue de \(label(unknown.source)) n’a pas été reconnue parmi les langues installées."), actions: [
                .navigate(String(localized: "Choisir la langue"), to: .languageChoice(id))], sticky: true))
        }
    }
    /// The voice separation models are on disk, as the pipeline helper reports.
    @Published private(set) var diarizerReady = false
    /// Whether heavy work can start now, for the controls that request it.
    var workAvailability: Availability<Never> { work.availability }
    /// The session being transcribed.
    var processingID: UUID? { if case .transcription(let id)? = work.running { id } else { nil } }
    /// The session being summarized.
    var summaryID: UUID? { if case .summary(let id)? = work.running { id } else { nil } }
    var voiceBusy: Bool { work.running?.kind == .voice }
    /// Language installing right now, shown next to its row.
    var installingSpeechLocale: String? { if case .speechModel(let locale)? = work.running { locale } else { nil } }
    var isInstallingDiarizer: Bool { work.running == .diarizer }
    /// Some edit has not reached the store yet, or its save failed.
    var hasUnsavedChanges: Bool { sessionLibrary.hasUnsavedChanges }
    @Published var appearancePreference: AppearancePreference = .system {
        didSet {
            workspace.settings.set(appearancePreference.rawValue, for: .appearance)
            if appliesAppearance { NSApp.appearance = appearancePreference.appearance }
        }
    }
    /// Preferences read at start: the user's for the installed app, in memory for previews, tests
    /// and synthetic checks. Changes go to the workspace's settings.
    private var preferences: SettingsStore { environment.preferences }
    private var appliesAppearance: Bool { environment.appliesAppearance }
    let calendar: CalendarIntegration
    /// Paths to `hwyd-pipeline` and `hwyd-mcp`.
    var helpers: HelperLocator { environment.helpers }
    var dataDirectory: URL { environment.dataDirectory }
    /// The store of the sessions shown; nil for the examples and previews.
    var store: SessionStore? { workspace.store }
    /// The audio of the sessions shown; nil for the examples and previews, which hold none.
    var audio: (any AudioLocator)? { workspace.audio }
    var showWindow: (() -> Void)?
    var openNotepad: (() -> Void)?
    /// Moves the playhead while something plays.
    private var playbackClock: Timer?
    let player = SessionPlayback()

    init(environment: AppEnvironment) {
        self.environment = environment
        toastCenter = environment.toasts; notifier = environment.notifier ?? environment.toasts
        let preferences = environment.preferences
        workspace = environment.startsWithExamples ? environment.examples() : environment.user
        calendar = CalendarIntegration(settings: preferences, allowed: environment.usesSystem)
        coordinator = environment.coordinator
        // Previews, demos and tests never touch the keychain nor start a process to find agents.
        summarySettings = SummarySettings(store: preferences, usesSystem: environment.usesSystem, notifier: notifier, discovery: environment.agentDiscovery,
                                          secrets: environment.secrets)
        newSessionKind = preferences.value(.newSessionKind)
        diarizationEnabled = preferences.value(.diarizationEnabled)
        if let data = preferences.value(.recordingShortcut) {
            recordingShortcut = data.isEmpty ? nil : (try? JSONDecoder().decode(RecordingShortcut.self, from: data)) ?? .standard
        }
        appearancePreference = AppearancePreference(rawValue: preferences.value(.appearance) ?? "") ?? .system
        if appliesAppearance { NSApp.appearance = appearancePreference.appearance }
        if let locales = environment.initialLocales { installedSpeechLocales = locales.installed; supportedSpeechLocales = locales.supported }
        if let error = environment.startupError { notifier.notify(.error(error)) }
        summarySettings.isDemo = workspace.isExamples
        toastCenter.navigate = { [weak self] intent in self?.navigate(to: intent) }
        summarySettingsChanges = summarySettings.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        let coordinator = coordinator
        if environment.user.store != nil {
            // Only the user's own sessions, never the examples. The delay keeps the « Annuler »
            // offered after a voice correction usable.
            let library = environment.user.library
            let trigger = AutomaticSummaryTrigger(delay: environment.automaticSummaryDelay, enabledSince: summarySettings.automaticSince,
                                                  sessions: { [weak library] in library?.recordings ?? [] },
                                                  request: { [weak self] id in self?.enqueue { [weak self] in await self?.requestSummary(id, automatic: true) } })
            automaticSummary = trigger
            automaticSummarySetting = summarySettings.$automaticSince.sink { [weak self] since in
                MainActor.assumeIsolated {
                    // Only on a change: the publisher also sends the current value when subscribed.
                    let turnedOff = since == nil && trigger.enabledSince != nil
                    trigger.enabledSince = since
                    if turnedOff { self?.dropQueuedAutomaticSummaries() }
                }
            }
        }
        Task { [weak self] in
            for await snapshot in await coordinator.snapshots() { self?.show(snapshot) }
        }
        Task { [weak self] in
            for await busy in await coordinator.busyChanges() { self?.workBusy = busy }
        }
        captureChanges = [
            captureSession.$phase.sink { [weak self] in self?.showCapture($0) },
            captureSession.$levels.sink { [weak self] in self?.micLevel = $0.mic; self?.systemLevel = $0.system }
        ]
        captureSession.onEnd = { [weak self] in self?.showCaptureEnd($0) }
        if environment.user.store != nil {
            let changes = environment.user.library.changes
            Task { [weak self] in
                for await change in changes { self?.report(change) }
            }
        }
    }
    /// Tells the user what the library could not do on its own.
    private func report(_ change: LibraryChange) {
        switch change {
        case .saved, .external, .rebased: automaticSummary?.sessionsChanged()
        default: break
        }
        switch change {
        case .saveFailed(let reason):
            notifier.notify(.error(String(localized: "Les dernières modifications ne sont pas enregistrées : \(reason)"),
                                   actions: [.perform(String(localized: "Réessayer")) { [weak self] in self?.retrySave() }]))
        case .exportDeferred(let reason): notifier.notify(.info(String(localized: "Export différé : \(reason)")))
        case .filesLeft(let files): reportLeftoverFiles(files)
        case .fileSweepFailed(let reason): notifier.notify(.error(reason))
        case .rebased(let id, let conflicts) where !conflicts.isEmpty:
            let title = recordings.first { $0.id == id }?.title ?? ""
            notifier.notify(.info(String(localized: "« \(title) » a aussi été modifiée par un autre outil. Vos modifications ont été gardées.")))
        case .removedElsewhere(_, let title):
            notifier.notify(.info(String(localized: "« \(title) » a été supprimée par un autre outil. Vos modifications en attente sont abandonnées.")))
        case .saved, .external, .rebased: break
        }
    }
    /// Loads the sessions of the store shown, if any: the examples and previews have nothing to load.
    func load() async {
        guard let store else { return }
        let library = sessionLibrary
        refreshSpeechLanguages()
        do {
            let count = try await library.load()
            people = try await store.people()
            mcpWritesEnabled = try await store.mcpWritesEnabled()
            exportDirectory = try await store.exportDirectory()?.path ?? ""
            // A transcription the app quit during cannot resume.
            for item in recordings where item.transcriptState == .pending {
                update(item.id) { $0.transcriptState = .failed }
            }
            if count > 0 { notifier.notify(.info(String(localized: "\(count) session(s) interrompue(s) retrouvée(s). Vos notes sont conservées."))) }
            automaticSummary?.adoptCurrentSessions()
        } catch { notifier.notify(.error(error.localizedDescription)) }
    }
    var selected: Recording? { recordings.first { $0.id == selectedID } }
    var activeCapture: Recording? { recordings.first { $0.id == activeCaptureID } }
    var filteredRecordings: [Recording] {
        recordings.filter { item in
            (kindFilter == nil || item.kind == kindFilter) && (search.isEmpty || item.searchableText.localizedStandardContains(search))
        }.sorted { $0.startedAt > $1.startedAt }
    }
    var todayRecordings: [Recording] { filteredRecordings.filter { Calendar.current.isDateInToday($0.startedAt) } }
    var olderRecordings: [Recording] { filteredRecordings.filter { !Calendar.current.isDateInToday($0.startedAt) } }
    func select(_ item: Recording) { showSettings = false; showNewSession = false; stopPlayback(); selectedID = item.id; activeTab = .defaultTab(for: item); playbackTime = 0; playback.activeSegmentIDs = []; mutedTracks = []; soloTracks = []; trackEnvelopes = [:] }
    func library() { showSettings = false; showNewSession = false; stopPlayback(); selectedID = nil; search = "" }
    /// Shows the examples, with the adapters the root gives them. Nothing runs or waits meanwhile.
    func enterDemo() {
        guard activeCaptureID == nil, !work.isBusy, pendingRequests == 0, !hasUnsavedChanges else { return }
        calendar.suspend()
        stopPlayback(); selectedID = nil; use(environment.examples())
    }
    /// Back to the user's sessions; a simulated capture is dropped with the examples.
    func leaveDemo() {
        stopPlayback(); activeCaptureID = nil; selectedID = nil; use(environment.user)
        Task { await captureSession.discard(); await load(); calendar.start() }
    }
    private func use(_ next: Workspace) {
        workspace = next
        // Summary settings changed among the examples are neither saved nor checked against the keychain.
        summarySettings.isDemo = next.isExamples
    }
    /// Edits the session now; the library saves it shortly after.
    func update(_ id: UUID, _ edit: (inout Recording) -> Void) { sessionLibrary.edit(id, edit) }
    /// Saves pending edits now.
    func flush() async { await sessionLibrary.flush() }
    func retrySave() { Task { await sessionLibrary.flush() } }
    func addTimestamp() {
        guard let id = activeCaptureID else { return }
        let offset = captureSession.sessionID == id ? captureSession.elapsed : elapsed
        update(id) { $0.noteEntries.append(.init(offset: offset)) }
    }
    func beginSpeakerEdit(_ speaker: Speaker) { editingSpeakerID = speaker.id; speakerName = speaker.confirmed || speaker.proposedIdentity != nil ? speaker.label : "" }
    /// Names the voice if needed, then adds a sample of it to the person's voice print. The
    /// channel follows the voice's track. Only an explicit request from the user leads here.
    func rememberSpeaker(name: String, speakerID: UUID) {
        guard let id = selectedID, !voiceEditingLocked, var item = selected,
              let speaker = item.speakers.first(where: { $0.id == speakerID }) else { return }
        let person: VoicePerson
        do throws(EnrollmentRefusal) { person = try EnrollVoice.person(named: name, for: speaker, among: people) } catch {
            notifier.notify(.enrollmentRefused(error)); return
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !(speaker.confirmed && speaker.label == name) {
            do { try item.renameSpeaker(speakerID, to: name); update(id) { $0 = item } } catch { notifier.notify(.error(error.localizedDescription)); return }
        }
        editingSpeakerID = nil
        enrollVoice(speakerID, as: person)
    }
    /// Asks for confirmation before memorizing an already named voice.
    func requestEnrollment(_ speakerID: UUID) { enrollmentCandidateID = speakerID }
    func confirmEnrollment() {
        guard let speakerID = enrollmentCandidateID, let speaker = selected?.speakers.first(where: { $0.id == speakerID }) else { return }
        enrollmentCandidateID = nil
        rememberSpeaker(name: speaker.label, speakerID: speakerID)
    }
    func confirmSpeaker() {
        guard selectedID != processingID, let speakerID = editingSpeakerID else { return }
        let name = speakerName.trimmingCharacters(in: .whitespacesAndNewlines), people = self.people
        let applied = editVoices({ _ in String(localized: "Voix nommée \(name) dans toute cette session.") }) { item in
            // Keeping the proposed person's name confirms the proposal; another name only renames.
            let proposal = item.speakers.first { $0.id == speakerID }?.proposedIdentity
            if let proposal, let person = people.first(where: { $0.id == proposal.personID && $0.recognitionEnabled }), person.name == name {
                try item.linkSpeaker(speakerID, to: person)
            } else { try item.renameSpeaker(speakerID, to: name) }
        }
        if applied { editingSpeakerID = nil }
    }
    func assignSpeaker(_ speakerID: UUID?, to segmentID: UUID, recordingID: UUID) {
        guard recordingID != processingID,
              var item = recordings.first(where: { $0.id == recordingID }), item.state != .recording else { return }
        do {
            let previousVersion = item.transcriptVersion
            try item.assignSpeaker(speakerID, to: segmentID)
            guard item.transcriptVersion != previousVersion else { return }
            update(recordingID) { $0 = item }
            notifier.notify(.info(String(localized: "Attribution corrigée pour ce passage uniquement.")))
        } catch { notifier.notify(.error(error.localizedDescription)) }
    }
    @discardableResult
    func splitSegment(_ segment: TranscriptSegment, beforeWord index: Int, recordingID: UUID) -> Bool {
        guard recordingID != processingID,
              var item = recordings.first(where: { $0.id == recordingID }), item.state != .recording else { return false }
        do {
            guard item.segments.first(where: { $0.id == segment.id }) == segment else { throw StoreError.conflict }
            try item.splitSegment(segment.id, beforeWord: index)
            update(recordingID) { $0 = item }
            notifier.notify(.info(String(localized: "Passage découpé. Vous pouvez corriger la voix de chaque partie.")))
            return true
        } catch { notifier.notify(.error(error.localizedDescription)); return false }
    }
    /// Records the event; `openLink` also opens its video link first.
    func joinMeeting(_ event: CalendarContext, openLink: Bool = true) {
        showWindow?()
        // A meeting is recorded for real: never into a simulation.
        guard !workspace.capture.isSimulated, activeCaptureID == nil, !isStarting else {
            notifier.notify(.info(String(localized: "Une capture est déjà en cours."))); return
        }
        if let existing = recordings.first(where: { $0.calendarContext?.id == event.id }) {
            select(existing); notifier.notify(.info(String(localized: "Cette réunion possède déjà une session."))); return
        }
        if openLink, let url = event.meetingURL { NSWorkspace.shared.open(url) }
        startCapture(meeting: event)
    }
    /// Pauses or resumes the active capture without ending the session.
    /// Paused time is left out of the recording timeline, so notes stay aligned with the audio.
    @discardableResult
    func toggleCapturePause() -> Task<Void, Never> {
        Task {
            if captureSession.isPaused { await captureSession.resume() } else { await captureSession.pause() }
            if captureSession.sessionID != nil { elapsed = captureSession.elapsed }
        }
    }
    // MARK: Navigation

    /// Takes the user where a notice's action points. A session deleted since is ignored.
    func navigate(to intent: NavigationIntent) {
        switch intent {
        case .session(let id, let artifact):
            guard let item = recordings.first(where: { $0.id == id }) else { return }
            select(item)
            switch artifact {
            case .notes: activeTab = .notes
            case .summary: activeTab = .summary
            case .transcript: activeTab = .transcript
            case nil: break
            }
        case .languageChoice(let id): chooseLanguage(for: id)
        case .summarySettings: settingsCategory = .summary; showSettings = true
        }
    }

    // MARK: Capture

    /// Opens the setup screen, or the running capture if there is one.
    func requestNewSession() {
        if let active = activeCapture { select(active); showWindow?(); return }
        showSettings = false; stopPlayback(); selectedID = nil
        newSessionTitle = ""; newSessionLanguage = SpeechLanguage.automatic
        showNewSession = true
        refreshSpeechLanguages(); showWindow?()
    }
    /// Starts recording. A calendar meeting provides its own kind and title; otherwise the
    /// setup screen does, and an empty name falls back to the kind and time.
    @discardableResult
    func startCapture(meeting: CalendarContext? = nil, kind: SessionKind? = nil, title: String? = nil, language: String? = nil, reveal: Bool = true) -> Task<Void, Never> {
        guard activeCaptureID == nil, !isStarting else { if reveal { showWindow?() }; return Task {} }
        let request = CaptureRequest(kind: kind ?? .adHoc, title: title, meeting: meeting, language: language)
        showSettings = false; showNewSession = false
        stopPlayback(); isStarting = true
        let workspace = workspace
        return Task {
            defer { isStarting = captureSession.isStarting }
            do {
                // The root chose the capture: Core Audio for the installed app's own data only.
                let capture = try workspace.capture.make()
                guard try await captureSession.start(request, with: capture, in: workspace.library) != nil else { return }
                if reveal { showWindow?() }
            } catch { notifier.notify(.error(error.localizedDescription)); if !reveal { showWindow?() } }
        }
    }
    /// Ends the capture. `reveal` brings the window forward on the notes; the shortcut, used from
    /// another application, leaves it where it is.
    @discardableResult
    func stopCapture(reveal: Bool = true) -> Task<Void, Never> {
        Task {
            if await captureSession.stop() != nil, reveal { showWindow?() }
        }
    }
    /// The Mac is going to sleep: the session ends with what was recorded.
    func systemWillSleep() { Task { await captureSession.systemWillSleep() } }
    /// Mirrors the capture's phase in the published state the views read.
    private func showCapture(_ phase: CapturePhase) {
        if shownCapturePhase == .starting, case .recording(let id) = phase { selectedID = id; elapsed = 0 }
        shownCapturePhase = phase
        activeCaptureID = phase.sessionID
        isCapturePaused = if case .paused = phase { true } else { false }
        if phase == .starting { isStarting = true }
        if phase.sessionID == nil { captureClock?.invalidate(); captureClock = nil }
        else if captureClock == nil { captureClock = repeating { [weak self] in self?.tickCapture() } }
    }
    /// Shows the notes of the session that just ended. A capture that ended on its own (sleep, a
    /// fault) or failed to seal brings the window forward; one the user stopped is revealed by
    /// `stopCapture(reveal:)`.
    private func showCaptureEnd(_ ending: CaptureEnding) {
        selectedID = ending.sessionID; activeTab = .notes
        if ending.cause != .requested || ending.finalizationError != nil { showWindow?() }
    }
    // MARK: Heavy work

    /// Stops the running transcription, installation or voice job, and drops waiting transcriptions.
    func cancelProcessing() { enqueue { [coordinator] in await coordinator.cancel { $0.kind != .summary } } }
    /// Stops or drops this session's transcription.
    func cancelTranscription(_ id: UUID) { enqueue { [coordinator] in await coordinator.cancel(.transcription(session: id)) } }
    /// Returns once every request made so far is decided and no work runs or waits.
    func idle() async {
        while true {
            let chain = requestChain
            await chain?.value
            await coordinator.idle()
            if requestChain == chain || Task.isCancelled { break }
        }
        show(await coordinator.snapshot)
    }
    private func show(_ snapshot: WorkSnapshot) {
        if snapshot.revision > work.revision { work = snapshot }
    }
    private func updateBusy() {
        let busy = activeCaptureID != nil || workBusy
        if busy != isBusy { isBusy = busy }
    }
    /// Runs a trigger's request after the ones made before it and returns its result.
    private func enqueued<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            enqueue { continuation.resume(returning: await body()) }
        }
    }
    /// Runs a trigger's request after the ones made before it.
    private func enqueue(_ body: @escaping @MainActor () async -> Void) {
        let previous = requestChain
        pendingRequests += 1
        requestChain = Task {
            await previous?.value
            await body()
            pendingRequests -= 1
        }
    }
    /// Hands a job to the coordinator and tells the user why it was refused.
    @discardableResult
    /// `automatic` requests wait their turn and are refused silently: nobody asked for them, and
    /// the controls they would have used already say why they cannot run.
    private func request(_ job: WorkJob, automatic: Bool = false, _ run: @escaping @MainActor @Sendable () async -> Void) async -> WorkDecision {
        let decision = await coordinator.request(job, waits: automatic ? true : nil) { await run() }
        show(await coordinator.snapshot)
        if case .refused(let refusal) = decision, !automatic { notifier.notify(.refusal(refusal)) }
        return decision
    }
    /// A request the session or the service cannot serve, said to the user.
    private func refuse(_ refusal: WorkRefusal) -> WorkDecision {
        notifier.notify(.refusal(refusal))
        return .refused(refusal)
    }

    func installSpeechModel(_ locale: String, then completion: (@MainActor @Sendable () -> Void)? = nil) {
        enqueue { [weak self] in await self?.requestSpeechModel(locale, then: completion) }
    }
    /// Installs a language. `completion` runs after a successful install; the work it requests
    /// waits for the install to end.
    @discardableResult
    func requestSpeechModel(_ locale: String, then completion: (@MainActor @Sendable () -> Void)? = nil) async -> WorkDecision {
        let speechModels = speechModels
        if let refusal = speechModels.refusal { return refuse(refusal) }
        return await request(.speechModel(locale: locale)) { [weak self] in
            guard let self else { return }
            do {
                try await speechModels.install(locale: locale)
                notifier.notify(.info(String(localized: "Langue installée : \(SpeechLanguage.displayName(locale)). La transcription reste locale.")))
                completion?()
            } catch { notifier.notify(.error(error.localizedDescription)) }
            refreshSpeechLanguages()
        }
    }
    func installDiarizer() { enqueue { [weak self] in await self?.requestDiarizer() } }
    @discardableResult
    func requestDiarizer() async -> WorkDecision {
        let speechModels = speechModels
        if let refusal = speechModels.refusal { return refuse(refusal) }
        return await request(.diarizer) { [weak self] in
            guard let self else { return }
            do {
                try await speechModels.installDiarizer()
                diarizerReady = await speechModels.diarizerReady()
                diarizationEnabled = true
                notifier.notify(.info(String(localized: "Séparation des voix activée pour les prochains traitements.")))
            } catch { notifier.notify(.error(String(localized: "Installation des voix : \(error.localizedDescription)"))) }
        }
    }
    /// `language` replaces the session's language for this run and becomes its new choice.
    func transcribe(_ id: UUID, language: String? = nil) {
        enqueue { [weak self] in await self?.requestTranscription(id, language: language) }
    }
    /// Starts the transcription, or queues it behind the work in progress.
    @discardableResult
    func requestTranscription(_ id: UUID, language: String? = nil) async -> WorkDecision {
        let workspace = workspace
        if let refusal = workspace.transcription.refusal { return refuse(refusal) }
        guard let item = workspace.library.recording(id), item.state != .recording, !item.audioChunks.isEmpty else { return refuse(.noAudio) }
        return await request(.transcription(session: id)) { [weak self] in await self?.runTranscription(id, language: language, in: workspace) }
    }
    /// The session is read when its turn comes: edits made while it waited are kept.
    private func runTranscription(_ id: UUID, language: String?, in workspace: Workspace) async {
        let library = workspace.library
        guard let item = library.recording(id), item.state != .recording, !item.audioChunks.isEmpty else { return }
        let originalVersion = item.transcriptVersion
        library.edit(id) { $0.transcriptState = .pending }
        do {
            await library.flush()
            guard !library.hasUnsavedChanges else { throw PipelineFailure(message: String(localized: "Sauvegardez les modifications avant de transcrire.")) }
            // The languages the transcribing process can use, or the last ones read.
            let locales = (try? await workspace.speechModels.locales()) ?? SpeechLocales(installed: installedSpeechLocales, supported: supportedSpeechLocales)
            showSpeechLocales(locales)
            let request = TranscriptionRequest(session: item, language: language, diarize: diarizationEnabled, locales: locales)
            let result = try await workspace.transcription.transcribe(request)
            do {
                try await library.apply(id, ifStillAt: originalVersion) { latest in
                    try latest.applyTranscription(result)
                    if let language { latest.speechLanguage = language }
                }
            } catch is StaleResult { throw TranscriptionError.staleResult }
            catch is UnsavedResult { return } // The transcript stays pending; the save failure is shown.
            notifier.notify(.info(result.segments.isEmpty ? String(localized: "Traitement terminé : aucune parole reconnue.") : (result.diarizationEngine == nil ? String(localized: "Transcript disponible. Les voix ne sont pas séparées.") : String(localized: "Transcript disponible. Les voix détectées peuvent être nommées dans cette session."))))
            if let warning = result.identityWarning { notifier.notify(.info(String(localized: "Transcript disponible.") + " " + warning)) }
            if let detections = result.languageDetection { reportLanguageFindings(detections, id: id) }
        } catch {
            library.edit(id) { $0.transcriptState = .failed }
            notifier.notify(.error(String(localized: "Transcription : \(error.localizedDescription)"),
                                   actions: [.perform(String(localized: "Réessayer")) { [weak self] in self?.transcribe(id, language: language) }]))
            await library.flush()
        }
    }
    /// A 200 ms timer on the main run loop. Common modes keep it running while the user scrolls or drags.
    private func repeating(_ tick: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in Task { @MainActor in tick() } }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
    /// The session clock counts recorded time; the capture reports levels and faults itself.
    private func tickCapture() {
        if captureSession.sessionID != nil { elapsed = captureSession.elapsed }
    }
    private func tickPlayback() {
        guard isPlaying else { return }
        playbackTime = player.position
        if player.playlistFinished || playbackTime >= (selected?.duration ?? 0) { stopPlayback() }
        updatePlaybackFocus()
    }
    /// Starts the playhead clock; `stopPlayback()` stops it.
    func startPlaybackClock() {
        if playbackClock == nil { playbackClock = repeating { [weak self] in self?.tickPlayback() } }
    }
    func isTrackAudible(_ source: AudioSource) -> Bool {
        !mutedTracks.contains(source) && (soloTracks.isEmpty || soloTracks.contains(source))
    }
    func toggleMute(_ source: AudioSource) {
        if !mutedTracks.insert(source).inserted { mutedTracks.remove(source) }
        applyTrackMix()
    }
    func toggleSolo(_ source: AudioSource) {
        if !soloTracks.insert(source).inserted { soloTracks.remove(source) }
        applyTrackMix()
    }
    private func applyTrackMix() {
        for source in [AudioSource.mic, .system] { player.setAudible(source, isTrackAudible(source)) }
    }
    func togglePlayback() {
        if isPlaying { playbackTime = player.position; stopPlayback(); return }
        play(at: playbackTime >= (selected?.duration ?? 0) ? 0 : playbackTime)
    }
    func seekPlayback(to time: Double) {
        let resume = isPlaying
        stopPlayback(); playbackTime = min(max(0, time), selected?.duration ?? 0)
        if resume { play(at: playbackTime) } else { updatePlaybackFocus() }
    }
    func play(at time: Double) {
        guard let item = selected, let audio, !item.audioChunks.isEmpty else {
            notifier.notify(.info(String(localized: "Aucun fichier audio disponible pour cette session."))); return
        }
        stopPlayback()
        do {
            playbackTime = min(max(0, time), item.duration)
            try player.start(chunks: item.audioChunks, audio: audio, at: playbackTime, duration: item.duration)
            applyTrackMix(); isPlaying = true; playback.generation += 1; updatePlaybackFocus(); startPlaybackClock()
        } catch { notifier.notify(.error(String(localized: "Lecture impossible : \(error.localizedDescription)"))) }
    }
    func stopPlayback() {
        player.stop(); isPlaying = false; playback.voiceID = nil
        playbackClock?.invalidate(); playbackClock = nil
    }
    func loadWaveforms(for item: Recording) async {
        trackEnvelopes = [:]; waveformError = nil
        guard let audio, !item.audioChunks.isEmpty else { waveformLoading = false; return }
        waveformLoading = true
        do {
            let envelopes = try await waveformReader.read(chunks: item.audioChunks, audio: audio, duration: item.duration)
            guard !Task.isCancelled, selectedID == item.id else { return }
            trackEnvelopes = envelopes; waveformLoading = false
        } catch {
            guard !Task.isCancelled, selectedID == item.id else { return }
            waveformLoading = false; waveformError = String(localized: "Formes d’onde indisponibles")
        }
    }
    // MARK: Voice memory

    /// Requests a voice memory job, about `session` or about people only, and reports its failure.
    private func runVoiceRequest(session: UUID? = nil, _ body: @escaping @MainActor @Sendable (VoiceRequests, SessionLibrary) async throws -> VoiceResult) {
        enqueue { [weak self] in await self?.requestVoice(session: session, body) }
    }
    /// The voice memory adapter refuses first (the examples), then a missing store; otherwise the
    /// job waits for the coordinator. Its typed result becomes the notice.
    @discardableResult
    private func requestVoice(session: UUID?, _ body: @escaping @MainActor @Sendable (VoiceRequests, SessionLibrary) async throws -> VoiceResult) async -> WorkDecision {
        let workspace = workspace
        if let refusal = workspace.voiceMemory.refusal { return refuse(refusal) }
        guard let store = workspace.store else { return refuse(.storeUnavailable) }
        let requests = VoiceRequests(people: store, memory: workspace.voiceMemory), library = workspace.library
        return await request(.voice(session: session)) { [weak self] in
            do { self?.show(try await body(requests, library)) }
            catch {
                self?.notifier.notify(.error(String(localized: "Identité vocale : \(error.localizedDescription)")))
                // A request can fail after changing someone, as an opposition whose erasure failed.
                if let people = try? await store.people() { self?.people = people }
            }
        }
    }
    private func show(_ result: VoiceResult) {
        people = result.people
        switch result.contributions {
        case .read(let personID, let sources)?: voiceContributions[personID] = sources
        case .cleared(let personID)?: voiceContributions[personID] = nil
        case .withdrawn(let personID, let source)?: voiceContributions[personID]?.removeAll { $0.recordingID == source }
        case nil: break
        }
        if let notice = UserNotice.voice(result.outcome) { notifier.notify(notice) }
    }
    /// Memorizes a voice of the selected session, then shows who its other voices resemble.
    private func enrollVoice(_ speakerID: UUID, as person: VoicePerson) {
        guard let item = selected else { return }
        runVoiceRequest(session: item.id) { requests, library in try await requests.enroll(person, speakerID: speakerID, in: item, library: library) }
    }
    /// Proposes a known person for the unconfirmed voices of the selected session.
    func identifyVoices() {
        guard let id = selected?.id else { return }
        enqueue { [weak self] in await self?.requestIdentification(of: id) }
    }
    /// Proposes a known person for the session's unconfirmed voices, as it is now.
    @discardableResult
    func requestIdentification(of id: UUID) async -> WorkDecision {
        guard let item = recordings.first(where: { $0.id == id }) else { return refuse(.sessionNotFound) }
        return await requestVoice(session: id) { requests, library in try await requests.identify(in: item, library: library) }
    }
    /// Reads what each session added to a person's voice print.
    func loadVoiceSources(of personID: UUID) {
        runVoiceRequest { requests, _ in try await requests.sources(of: personID) }
    }
    /// Erases a person's voice print. The name stays in sessions; the voice can be memorized again.
    func forgetVoice(of person: VoicePerson) {
        runVoiceRequest { requests, _ in try await requests.forget(person) }
    }
    /// Records the person's opposition, then erases their voice print. Also retries an erasure
    /// that failed after an opposition.
    func opposeVoice(of person: VoicePerson) {
        runVoiceRequest { requests, _ in try await requests.oppose(person) }
    }
    /// Withdraws what one session added to a person's voice print.
    func withdrawVoiceSource(_ recordingID: UUID?, of person: VoicePerson) {
        runVoiceRequest { requests, _ in try await requests.withdraw(recordingID, of: person) }
    }
    /// Ends an opposition. Any sample left by an interrupted erasure goes first, so recognition
    /// resumes only after a new enrollment.
    func liftOpposition(_ person: VoicePerson) {
        runVoiceRequest { requests, _ in try await requests.liftOpposition(person) }
    }
    func chooseSummaryAgentDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = String(localized: "Utiliser ce dossier"); panel.message = String(localized: "L’agent démarre dans ce dossier et y trouve son contexte (instructions, mémoire, notes).")
        if panel.runModal() == .OK, let url = panel.url {
            summarySettings.agentDirectory = (url.path as NSString).abbreviatingWithTildeInPath; summarySettings.save()
        }
    }
    func cancelSummary() { enqueue { [coordinator] in await coordinator.cancel { $0.kind == .summary } } }
    func cancelSummary(of id: UUID) { enqueue { [coordinator] in await coordinator.cancel(.summary(session: id)) } }
    /// The summarizer for the current settings, from the workspace: it owns whether a summary can
    /// run and why not. Only the installed app's reads keys from the keychain.
    var summarizer: any Summarizer { workspace.summarizer(summarySettings.configuration) }
    /// The summarizer's own conditions, then whether other work keeps it waiting.
    var summaryAvailability: SummaryAvailability { summarizer.availability.combined(with: work.availability) }
    /// Where the configured summarizer writes its draft and what leaves the Mac, as the summary tab shows it.
    var summaryDisclosure: SummaryDisclosure { summarizer.disclosure }
    /// Opens the session's summary and runs it again.
    func retrySummary(_ id: UUID) {
        guard recordings.contains(where: { $0.id == id }) else { return }
        navigate(to: .session(id, .summary)); generateSummary()
    }
    func generateSummary() {
        guard let id = selected?.id else { return }
        enqueue { [weak self] in await self?.requestSummary(id) }
    }
    /// Asks for a summary. An `automatic` request comes from `AutomaticSummaryTrigger`: it waits
    /// behind other work, and a refusal (summary turned off, provider not configured) says nothing,
    /// since the summary tab already explains why under its Generate button.
    @discardableResult
    func requestSummary(_ recordingID: UUID, automatic: Bool = false) async -> WorkDecision {
        let summarizer = summarizer, library = sessionLibrary
        // An automatic request is refused silently: nobody asked for it.
        if let refusal = summarizer.refusal { return automatic ? .refused(refusal) : refuse(refusal) }
        guard store != nil, library.recording(recordingID) != nil else { return automatic ? .refused(.sessionNotFound) : refuse(.sessionNotFound) }
        if case .unavailable(let reason) = summarizer.availability {
            if !automatic {
                notifier.notify(.error(String(localized: "Synthèse : \(reason.localizedDescription)"), actions: [
                    .navigate(String(localized: "Réglages"), to: .summarySettings)]))
            }
            return .refused(.unavailable(reason.localizedDescription))
        }
        if automatic { automaticSummaryJobs.insert(recordingID) }
        let decision = await request(.summary(session: recordingID), automatic: automatic) { [weak self] in
            await self?.runSummary(recordingID, with: summarizer, in: library, automatic: automatic)
        }
        if automatic, case .refused = decision { automaticSummaryJobs.remove(recordingID) }
        return decision
    }
    /// Turning the automatic summary off drops the automatic runs still waiting; one already
    /// running goes on. Ordered after the requests in flight, so none is queued after the drop.
    private func dropQueuedAutomaticSummaries() {
        enqueue { [weak self] in
            guard let self else { return }
            let sessions = automaticSummaryJobs
            await coordinator.dropQueued { job in
                if case .summary(let id) = job { sessions.contains(id) } else { false }
            }
            show(await coordinator.snapshot)
        }
    }
    private func runSummary(_ recordingID: UUID, with summarizer: any Summarizer, in library: SessionLibrary, automatic: Bool) async {
        defer { summaryProgress = nil; if automatic { automaticSummaryJobs.remove(recordingID) } }
        do {
            // Capture the revision only after pending UI edits have reached the store.
            // Otherwise the normal autosave can make our own snapshot look stale.
            await library.flush()
            try Task.checkCancellation()
            guard !library.hasUnsavedChanges else { return } // flush already exposes the save error.
            guard let item = library.recording(recordingID) else { throw SummaryFailure.stale }
            if automatic {
                // Queued behind other work: the setting may have been turned off, the session may
                // have changed or got its summary meanwhile.
                guard summarySettings.automatic, item.isReadyForSummary else { return }
                notifier.notify(UserNotice(style: .info, message: String(localized: "Synthèse automatique lancée : \(item.title)"),
                                           actions: [.perform(String(localized: "Annuler")) { [weak self] in self?.cancelSummary(of: recordingID) }],
                                           optional: true))
            }
            let result = try await summarizer.summarize(item) { value in
                await MainActor.run { self.summaryProgress = value }
            }
            try Task.checkCancellation()
            // Stale once the transcript or anything the summary read changed, here or in another process.
            do {
                try await library.apply(item.id, ifStillAt: item.transcriptVersion, where: { try SummaryPipeline.inputHash($0) == result.inputHash }) {
                    $0.summary = result.structured.markdown; $0.summaryProvenance = result
                }
            } catch is StaleResult { throw SummaryFailure.stale }
            catch is UnsavedResult { return } // The summary stays pending; the save failure is shown.
            // A long run (agents take minutes) may finish while another screen is open.
            let showsSummary = selectedID == item.id && activeTab == .summary && !showSettings
            notifier.notify(.success(String(localized: "Synthèse prête : \(item.title)"),
                                     actions: showsSummary ? [] : [.navigate(String(localized: "Afficher"), to: .session(item.id, .summary))]))
        } catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                notifier.notify(.info(String(localized: "Synthèse annulée.")))
            } else if automatic, case SummaryFailure.stale = error {
                // The session changed while the run read it: requested again once ready and quiet.
                automaticSummary?.runWasStale(recordingID)
            } else {
                notifier.notify(.error(String(localized: "Synthèse : \(error.localizedDescription)"), actions: [
                    .perform(String(localized: "Réessayer")) { [weak self] in self?.retrySummary(recordingID) },
                    .navigate(String(localized: "Réglages"), to: .summarySettings)]))
            }
        }
    }
    func setMCPWrites(_ enabled: Bool) {
        guard let store else { return }
        Task {
            do { try await store.setMCPWritesEnabled(enabled); mcpWritesEnabled = enabled }
            catch { notifier.notify(.error(error.localizedDescription)) }
        }
    }
    func chooseExportDirectory() {
        guard let store else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = String(localized: "Utiliser ce dossier"); panel.message = String(localized: "Les sessions sauvegardées seront publiées ici en Markdown et JSON.")
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await store.setExportDirectory(url); exportDirectory = url.path
                    await flush()
                    try await sessionLibrary.publishExports()
                    notifier.notify(.info(String(localized: "Dossier de publication configuré.")))
                } catch { notifier.notify(.error(String(localized: "Export différé : \(error.localizedDescription)"))) }
            }
        }
    }
    func exportSelected() {
        guard let item = selected else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = String(localized: "Exporter ici"); panel.message = String(localized: "Choisissez le dossier de sortie pour cette session.")
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await flush()
                guard !hasUnsavedChanges else { return }
                do {
                    let current = recordings.first { $0.id == item.id } ?? item
                    try await FolderExportPublisher(directory: url).publish(current); notifier.notify(.info(String(localized: "Session exportée en Markdown et JSON."))); NSWorkspace.shared.open(url)
                } catch { notifier.notify(.error(String(localized: "Export impossible : \(error.localizedDescription)"))) }
            }
        }
    }
    func deleteConfirmed() {
        guard let item = deleteCandidate, item.id != activeCaptureID else { return }
        deleteCandidate = nil
        // In the request order, so no job for this session can be requested between the check and the removal.
        enqueue { [weak self] in await self?.delete(item) }
    }
    /// Work running or waiting on the session blocks its deletion: a transcription, a summary or a voice job.
    private func delete(_ item: Recording) async {
        guard await coordinator.snapshot.jobs(for: item.id).isEmpty else { notifier.notify(.refusal(.sessionInUse)); return }
        do {
            let removal = try await sessionLibrary.remove(item.id)
            if selectedID == item.id { selectedID = nil }
            if let files = removal.files, !files.isComplete { reportLeftoverFiles(files) }
        } catch { notifier.notify(.error(error.localizedDescription)) }
    }
    /// The session is gone; its remaining files are retried on next launch.
    private func reportLeftoverFiles(_ report: SessionFiles.Report) {
        notifier.notify(.error(String(localized: "\(report.failures.count) fichier(s) de la session n’ont pas pu être effacés. Nouvel essai au prochain lancement.")
            + " " + (report.failures.first.map { "\($0.path) : \($0.reason)" } ?? "")))
    }
}
enum DetailTab: String, CaseIterable {
    case summary = "Synthèse", transcript = "Transcript", notes = "Notes" // l10n:ignore (rawValue, use title for display)
    /// The summary once one exists, the transcript otherwise.
    static func defaultTab(for item: Recording) -> DetailTab { item.summary == nil ? .transcript : .summary }
    var title: String {
        switch self {
        case .transcript: String(localized: "Transcript")
        case .notes: String(localized: "Notes")
        case .summary: String(localized: "Synthèse")
        }
    }
}
