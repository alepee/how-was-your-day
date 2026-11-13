import AppKit
import AVFoundation
import Combine
import Foundation
import HWYDCore

@MainActor
final class AppModel: ObservableObject {
    /// The sessions shown: the stored library, or a volatile one for previews and demo mode.
    /// Its edits, saves, merges with other writers and stale checks are its own.
    @Published private(set) var sessionLibrary = SessionLibrary(volatile: [])
    /// The library over the store, kept while demo mode shows the volatile one. Nil for previews
    /// and when the store cannot be opened.
    private var storedLibrary: SessionLibrary?
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
        didSet { if persistPreferences && !isDemoMode { settings.set(newSessionKind, for: .newSessionKind) } }
    }
    @Published var newSessionTitle = ""
    @Published var isDemoMode = false { didSet { summarySettings.isDemo = isDemoMode } }
    /// The library has not finished its first load.
    var isLoading: Bool { !sessionLibrary.isReady }
    /// Runs the capture: its clock, pause, end and what follows it. The properties below show
    /// its state; snapshots set them directly to render a capture.
    private(set) lazy var captureSession = CaptureSession(notifier: notifier) { [weak self] id in
        await self?.enqueued { [weak self] in await self?.requestTranscription(id) ?? .refused(.unavailable("")) } ?? .refused(.unavailable(""))
    }
    @Published var activeCaptureID: UUID? { didSet { updateBusy() } }
    @Published var elapsed: Double = 0
    /// The active capture is paused: no audio is captured and the clock is frozen.
    @Published var isCapturePaused = false
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var isStarting = false
    private var shownCapturePhase: CapturePhase = .idle
    private var captureChanges: [AnyCancellable] = []
    /// Whether the end of the capture being stopped brings the window forward.
    private var revealsCaptureEnd = true
    /// Only the installed app records for real. Previews and models opened on another directory
    /// (tests, synthetic checks) never open the microphone, even outside demo mode.
    private let microphoneAllowed: Bool
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
    let voiceMemory: any VoiceMemory
    /// Provider, model, key and agent settings of the summary. Its changes are republished by this model.
    let summarySettings: SummarySettings
    private var summarySettingsChanges: AnyCancellable?
    @Published var summaryProgress: SummaryProgress?
    @Published var diarizationEnabled = false {
        didSet { if persistPreferences && !isDemoMode { settings.set(diarizationEnabled, for: .diarizationEnabled) } }
    }
    /// Transcribes sessions, through the pipeline helper in the app.
    let transcription: any TranscriptionService
    /// Installed and installable speech languages and voice models.
    let speechModels: any SpeechModelCatalog
    /// Runs transcription, voice jobs, model installs and summaries one at a time. The model
    /// requests work and shows the coordinator's state; it keeps no busy flag of its own.
    let coordinator: WorkCoordinator
    /// The coordinator's latest state, as the views show it. Snapshots and synthetic checks set it
    /// directly to render or test a state.
    @Published var work = WorkSnapshot()
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
            if persistPreferences { settings.set(recordingShortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), for: .recordingShortcut) }
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
        guard !isDemoMode else { return }
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
            if persistPreferences && !isDemoMode { settings.set(appearancePreference.rawValue, for: .appearance) }
            if appliesAppearance { NSApp.appearance = appearancePreference.appearance }
        }
    }
    /// Preferences: the user's for the installed app, in memory for previews, tests and synthetic checks.
    private let settings: SettingsStore
    private let appliesAppearance: Bool
    private let persistPreferences: Bool
    let calendar: CalendarIntegration
    /// Paths to `hwyd-pipeline` and `hwyd-mcp`.
    let helpers: HelperLocator
    let dataDirectory: URL
    var store: SessionStore?
    var showWindow: (() -> Void)?
    var openNotepad: (() -> Void)?
    private var timer: Timer?
    let player = SessionPlayback()

    /// `settings` defaults to the user's preferences for the installed app only; previews and
    /// models opened on another directory get an empty in-memory store and never read them.
    /// The pipeline ports default to the bundled helper working on `dataDirectory`.
    init(directory: URL? = nil, preview: Bool = false, settings: SettingsStore? = nil, helpers: HelperLocator = .app,
         transcription: (any TranscriptionService)? = nil, voiceMemory: (any VoiceMemory)? = nil, speechModels: (any SpeechModelCatalog)? = nil,
         coordinator: WorkCoordinator = WorkCoordinator(), appliesAppearance: Bool = true, persistPreferences: Bool? = nil) {
        let installed = directory == nil && !preview
        let toastCenter = ToastCenter()
        self.toastCenter = toastCenter; notifier = toastCenter
        let settings = settings ?? (installed ? UserDefaultsSettings() : InMemorySettings())
        calendar = CalendarIntegration(settings: settings, allowed: installed)
        self.settings = settings
        self.helpers = helpers
        self.appliesAppearance = appliesAppearance
        self.persistPreferences = persistPreferences ?? installed
        microphoneAllowed = installed
        // Previews, demos and tests never touch the keychain nor start a process to find agents.
        summarySettings = SummarySettings(store: settings, usesSystem: self.persistPreferences, notifier: toastCenter,
                                          discovery: self.persistPreferences ? LoginShellAgentDiscovery() : FixedAgentDiscovery())
        newSessionKind = settings.value(.newSessionKind)
        diarizationEnabled = settings.value(.diarizationEnabled)
        if let data = settings.value(.recordingShortcut) {
            recordingShortcut = data.isEmpty ? nil : (try? JSONDecoder().decode(RecordingShortcut.self, from: data)) ?? .standard
        }
        appearancePreference = AppearancePreference(rawValue: settings.value(.appearance) ?? "") ?? .system
        let dataDirectory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HWYD")
        self.dataDirectory = dataDirectory
        self.transcription = transcription ?? HelperTranscriptionService(helpers: helpers, store: dataDirectory)
        self.voiceMemory = voiceMemory ?? HelperVoiceMemory(helpers: helpers, store: dataDirectory)
        self.speechModels = speechModels ?? HelperSpeechModelCatalog(helpers: helpers, store: dataDirectory)
        self.coordinator = coordinator
        if appliesAppearance { NSApp.appearance = appearancePreference.appearance }
        if preview {
            sessionLibrary = SessionLibrary(volatile: DemoContent.recordings()); isDemoMode = true
            installedSpeechLocales = ["fr-FR", "en-US"]; supportedSpeechLocales = ["de-DE", "en-US", "es-ES", "fr-FR"]
        } else {
            do {
                let store = try SessionStore(directory: dataDirectory)
                self.store = store
                // Asked at each publication, so a folder chosen later applies at once.
                let library = SessionLibrary(repository: store) { try await store.exportDirectory().map(FolderExportPublisher.init) }
                storedLibrary = library; sessionLibrary = library
            } catch {
                sessionLibrary = SessionLibrary(volatile: [])
                notifier.notify(.error(String(localized: "Impossible d’ouvrir les données locales : \(error.localizedDescription)")))
            }
        }
        summarySettings.isDemo = isDemoMode
        toastCenter.navigate = { [weak self] intent in self?.navigate(to: intent) }
        summarySettingsChanges = summarySettings.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
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
        if let changes = storedLibrary?.changes {
            Task { [weak self] in
                for await change in changes { self?.report(change) }
            }
        }
    }
    /// Tells the user what the library could not do on its own.
    private func report(_ change: LibraryChange) {
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
    func load() async {
        guard let store, let storedLibrary else { return }
        if sessionLibrary !== storedLibrary { sessionLibrary = storedLibrary }
        refreshSpeechLanguages()
        do {
            let count = try await storedLibrary.load()
            people = try await store.people()
            mcpWritesEnabled = try await store.mcpWritesEnabled()
            exportDirectory = try await store.exportDirectory()?.path ?? ""
            // A transcription the app quit during cannot resume.
            for item in recordings where item.transcriptState == .pending {
                update(item.id) { $0.transcriptState = .failed }
            }
            if count > 0 { notifier.notify(.info(String(localized: "\(count) session(s) interrompue(s) retrouvée(s). Vos notes sont conservées."))) }
        } catch { notifier.notify(.error(error.localizedDescription)) }
        startTicker()
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
    func enterDemo() {
        guard activeCaptureID == nil, !work.isBusy, pendingRequests == 0, !hasUnsavedChanges else { return }
        calendar.suspend()
        stopPlayback(); isDemoMode = true; selectedID = nil; sessionLibrary = SessionLibrary(volatile: DemoContent.recordings()); startTicker()
    }
    func leaveDemo() {
        stopPlayback(); activeCaptureID = nil; isDemoMode = false; selectedID = nil
        Task { await captureSession.discard(); await load(); calendar.start() }
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
            switch error {
            case .invalidName: notifier.notify(.error(String(localized: "Le nom doit contenir entre 1 et 120 caractères.")))
            case .opposed(let person): notifier.notify(.error(String(localized: "\(person.name) est exclue de la reconnaissance. Levez l’exclusion dans Réglages › Audio et voix.")))
            }
            return
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
        guard !isDemoMode, activeCaptureID == nil, !isStarting else {
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
        startTicker(); stopPlayback(); isStarting = true
        return Task {
            defer { isStarting = captureSession.isStarting }
            do {
                let capture = try makeCapture()
                guard try await captureSession.start(request, with: capture, in: sessionLibrary) != nil else { return }
                if reveal { showWindow?() }
            } catch { notifier.notify(.error(error.localizedDescription)); if !reveal { showWindow?() } }
        }
    }
    /// The capture for the mode: simulated in demo mode, Core Audio for the installed app.
    /// Composition-root seam (step 7): the mode should pick this once.
    private func makeCapture() throws -> any AudioCapture {
        if isDemoMode { return SimulatedCapture() }
        guard microphoneAllowed else { throw CaptureFailure(message: "This model never opens the microphone.") } // l10n:ignore
        guard store != nil else { throw CaptureFailure(message: String(localized: "Le store local n’est pas disponible.")) }
        return CoreAudioCapture(directory: dataDirectory)
    }
    @discardableResult
    func stopCapture(reveal: Bool = true) -> Task<Void, Never> {
        Task {
            revealsCaptureEnd = reveal
            await captureSession.stop()
            revealsCaptureEnd = true
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
    }
    /// Shows the notes of the session that just ended. A capture stopped by the user from
    /// elsewhere (the shortcut) leaves the window where it is, unless sealing failed.
    private func showCaptureEnd(_ ending: CaptureEnding) {
        selectedID = ending.sessionID; activeTab = .notes
        let reveal = ending.cause == .requested ? revealsCaptureEnd : true
        if reveal || ending.finalizationError != nil { showWindow?() }
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
    private func request(_ job: WorkJob, _ run: @escaping @MainActor @Sendable () async -> Void) async -> WorkDecision {
        let decision = await coordinator.request(job) { await run() }
        show(await coordinator.snapshot)
        if case .refused(let refusal) = decision { notifier.notify(.info(refusal.localizedDescription)) }
        return decision
    }
    /// A request the session or the mode cannot serve, said to the user.
    private func refuse(_ reason: String) -> WorkDecision {
        notifier.notify(.info(reason))
        return .refused(.unavailable(reason))
    }
    private var demoRefusal: WorkDecision { refuse(String(localized: "Les exemples ne lancent aucun traitement.")) }

    func installSpeechModel(_ locale: String, then completion: (@MainActor @Sendable () -> Void)? = nil) {
        enqueue { [weak self] in await self?.requestSpeechModel(locale, then: completion) }
    }
    /// Installs a language. `completion` runs after a successful install; the work it requests
    /// waits for the install to end.
    @discardableResult
    func requestSpeechModel(_ locale: String, then completion: (@MainActor @Sendable () -> Void)? = nil) async -> WorkDecision {
        guard !isDemoMode else { return demoRefusal }
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
        guard !isDemoMode else { return demoRefusal }
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
        guard !isDemoMode else { return demoRefusal }
        guard let item = recordings.first(where: { $0.id == id }), item.state != .recording, !item.audioChunks.isEmpty else {
            return refuse(String(localized: "Aucun fichier audio disponible pour cette session."))
        }
        return await request(.transcription(session: id)) { [weak self] in await self?.runTranscription(id, language: language) }
    }
    /// The session is read when its turn comes: edits made while it waited are kept.
    private func runTranscription(_ id: UUID, language: String?) async {
        guard let item = recordings.first(where: { $0.id == id }), item.state != .recording, !item.audioChunks.isEmpty else { return }
        let originalVersion = item.transcriptVersion
        update(id) { $0.transcriptState = .pending }
        do {
            await flush()
            guard !hasUnsavedChanges else { throw PipelineFailure(message: String(localized: "Sauvegardez les modifications avant de transcrire.")) }
            // The languages the transcribing process can use, or the last ones read.
            let locales = (try? await speechModels.locales()) ?? SpeechLocales(installed: installedSpeechLocales, supported: supportedSpeechLocales)
            showSpeechLocales(locales)
            let request = TranscriptionRequest(session: item, language: language, diarize: diarizationEnabled, locales: locales)
            let result = try await transcription.transcribe(request)
            do {
                try await sessionLibrary.apply(id, ifStillAt: originalVersion) { latest in
                    try latest.applyTranscription(result)
                    if let language { latest.speechLanguage = language }
                }
            } catch is StaleResult { throw TranscriptionError.staleResult }
            catch is UnsavedResult { return } // The transcript stays pending; the save failure is shown.
            notifier.notify(.info(result.segments.isEmpty ? String(localized: "Traitement terminé : aucune parole reconnue.") : (result.diarizationEngine == nil ? String(localized: "Transcript disponible. Les voix ne sont pas séparées.") : String(localized: "Transcript disponible. Les voix détectées peuvent être nommées dans cette session."))))
            if let warning = result.identityWarning { notifier.notify(.info(String(localized: "Transcript disponible.") + " " + warning)) }
            if let detections = result.languageDetection { reportLanguageFindings(detections, id: id) }
        } catch {
            update(id) { $0.transcriptState = .failed }
            notifier.notify(.error(String(localized: "Transcription : \(error.localizedDescription)"),
                                   actions: [.perform(String(localized: "Réessayer")) { [weak self] in self?.transcribe(id, language: language) }]))
            await flush()
        }
    }
    private func startTicker() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Common modes keep the playhead moving while the user scrolls or drags.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func tick() {
        // The session clock counts recorded time; the capture reports levels and faults itself.
        if captureSession.sessionID != nil { elapsed = captureSession.elapsed }
        if isPlaying {
            playbackTime = player.position
            if player.playlistFinished || playbackTime >= (selected?.duration ?? 0) { stopPlayback() }
            updatePlaybackFocus()
        }
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
        guard let item = selected, let store, !item.audioChunks.isEmpty else {
            notifier.notify(.info(String(localized: "Aucun fichier audio disponible pour cette session."))); return
        }
        stopPlayback()
        do {
            playbackTime = min(max(0, time), item.duration)
            try player.start(chunks: item.audioChunks, store: store, at: playbackTime, duration: item.duration)
            applyTrackMix(); isPlaying = true; playback.generation += 1; updatePlaybackFocus()
        } catch { notifier.notify(.error(String(localized: "Lecture impossible : \(error.localizedDescription)"))) }
    }
    func stopPlayback() { player.stop(); isPlaying = false; playback.voiceID = nil }
    func loadWaveforms(for item: Recording) async {
        trackEnvelopes = [:]; waveformError = nil
        guard let store, !item.audioChunks.isEmpty else { waveformLoading = false; return }
        waveformLoading = true
        do {
            let envelopes = try await waveformReader.read(chunks: item.audioChunks, store: store, duration: item.duration)
            guard !Task.isCancelled, selectedID == item.id else { return }
            trackEnvelopes = envelopes; waveformLoading = false
        } catch {
            guard !Task.isCancelled, selectedID == item.id else { return }
            waveformLoading = false; waveformError = String(localized: "Formes d’onde indisponibles")
        }
    }
    // MARK: Voice memory

    /// Requests a voice memory job, about `session` or about people only, and reports its failure.
    private func runVoiceJob(session: UUID? = nil, _ job: @escaping @MainActor @Sendable (SessionStore) async throws -> Void) {
        enqueue { [weak self] in await self?.requestVoiceJob(session: session, job) }
    }
    @discardableResult
    func requestVoiceJob(session: UUID?, _ job: @escaping @MainActor @Sendable (SessionStore) async throws -> Void) async -> WorkDecision {
        guard !isDemoMode else { return demoRefusal }
        guard let store else { return refuse(String(localized: "Le store local n’est pas disponible.")) }
        return await request(.voice(session: session)) { [weak self] in
            do { try await job(store) }
            catch { self?.notifier.notify(.error(String(localized: "Identité vocale : \(error.localizedDescription)"))) }
        }
    }
    /// Memorizes a voice of the selected session, then shows who its other voices resemble.
    private func enrollVoice(_ speakerID: UUID, as person: VoicePerson) {
        guard let item = selected else { return }
        runVoiceJob(session: item.id) { [weak self] store in
            guard let self else { return }
            let outcome = try await EnrollVoice(people: store, memory: voiceMemory)(person, speakerID: speakerID, in: item)
            people = outcome.people
            let name = outcome.person.name
            var proposed = 0
            // A transcript edited meanwhile, here or elsewhere, keeps the user's version.
            do {
                try await sessionLibrary.apply(item.id, ifStillAt: item.transcriptVersion) { current in
                    proposed = (try? current.applyEnrollment(outcome, speakerID: speakerID)) ?? 0
                }
            } catch is StaleResult { notifier.notify(.info(String(localized: "Voix de \(name) mémorisée."))); return }
            catch is UnsavedResult {} // The proposals stay pending; the save failure is shown.
            let found = proposed == 0 ? nil : proposed == 1 ? String(localized: "Une autre voix ressemble à une personne connue, à confirmer.")
                : String(localized: "\(proposed) autres voix ressemblent à des personnes connues, à confirmer.")
            notifier.notify(.info([String(localized: "Voix de \(name) mémorisée."), found].compactMap { $0 }.joined(separator: " ")))
        }
    }
    /// Proposes a known person for the unconfirmed voices of the selected session.
    func identifyVoices() {
        guard let item = selected else { return }
        runVoiceJob(session: item.id) { [weak self] store in
            guard let self else { return }
            let matches = try await voiceMemory.identify(in: item)
            people = try await store.people()
            var proposed = 0
            let people = people
            do {
                try await sessionLibrary.apply(item.id, ifStillAt: item.transcriptVersion) { proposed = $0.proposeIdentities(matches, people: people) }
            } catch is StaleResult {
                notifier.notify(.info(String(localized: "La session a changé pendant la reconnaissance. Aucune proposition appliquée."))); return
            } catch is UnsavedResult {} // The proposals stay pending; the save failure is shown.
            notifier.notify(.info(String(localized: "\(proposed) correspondance(s) proposée(s), à confirmer.")))
        }
    }
    /// Reads what each session added to a person's voice print.
    func loadVoiceSources(of personID: UUID) {
        runVoiceJob { [weak self] store in
            guard let self else { return }
            let sources = try await voiceMemory.sources(personID: personID)
            people = try await store.people()
            voiceContributions[personID] = sources
        }
    }
    /// Erases a person's voice print. The name stays in sessions; the voice can be memorized again.
    func forgetVoice(of person: VoicePerson) {
        runVoiceJob { [weak self] store in
            guard let self else { return }
            try await voiceMemory.forget(personID: person.id)
            people = try await store.people(); voiceContributions[person.id] = nil
            notifier.notify(.info(String(localized: "Empreinte de \(person.name) effacée. Sa voix ne sera plus reconnue avant une nouvelle mémorisation.")))
        }
    }
    /// Records the person's opposition, then erases their voice print. Also retries an erasure
    /// that failed after an opposition.
    func opposeVoice(of person: VoicePerson) {
        var opposed = person; opposed.opposed = true; opposed.consentedAt = nil
        runVoiceJob { [weak self] store in
            guard let self else { return }
            try await store.savePerson(opposed); people = try await store.people()
            try await voiceMemory.forget(personID: opposed.id)
            people = try await store.people(); voiceContributions[opposed.id] = nil
            notifier.notify(.info(String(localized: "Empreintes de \(opposed.name) supprimées. Opposition enregistrée.")))
        }
    }
    /// Withdraws what one session added to a person's voice print.
    func withdrawVoiceSource(_ recordingID: UUID?, of person: VoicePerson) {
        runVoiceJob { [weak self] store in
            guard let self else { return }
            try await voiceMemory.forget(personID: person.id, source: recordingID)
            people = try await store.people()
            voiceContributions[person.id]?.removeAll { $0.recordingID == recordingID }
            notifier.notify(.info(String(localized: "Apport retiré de l’empreinte de \(person.name).")))
        }
    }
    /// Ends an opposition. Any sample left by an interrupted erasure goes first, so recognition
    /// resumes only after a new enrollment.
    func liftOpposition(_ person: VoicePerson) {
        runVoiceJob { [weak self] store in
            guard let self else { return }
            try await voiceMemory.forget(personID: person.id)
            try await store.liftOpposition(person.id)
            people = try await store.people(); voiceContributions[person.id] = nil
            notifier.notify(.info(String(localized: "\(person.name) n’est plus exclue. Mémorisez sa voix depuis une session pour la reconnaître à nouveau.")))
        }
    }
    func chooseSummaryAgentDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = String(localized: "Utiliser ce dossier"); panel.message = String(localized: "L’agent démarre dans ce dossier et y trouve son contexte (instructions, mémoire, notes).")
        if panel.runModal() == .OK, let url = panel.url {
            summarySettings.agentDirectory = (url.path as NSString).abbreviatingWithTildeInPath; summarySettings.save()
        }
    }
    func cancelSummary() { enqueue { [coordinator] in await coordinator.cancel { $0.kind == .summary } } }
    private var summarizerEnvironment: SummarizerEnvironment {
        // Previews, demos and tests never touch the keychain.
        let readsKeychain = persistPreferences
        return SummarizerEnvironment(dataDirectory: dataDirectory,
                                     mcpExecutable: helpers.mcp) { service in
            readsKeychain ? try SummaryKeychain.key(for: service) : nil
        }
    }
    /// Replaces the configured summarizer in synthetic checks, so they run no model and no network call.
    var summarizerOverride: (any Summarizer)?
    /// The summarizer for the current settings. It owns whether a summary can run and why not.
    var summarizer: any Summarizer { summarizerOverride ?? SummarizerFactory.make(summarySettings.configuration, environment: summarizerEnvironment) }
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
    @discardableResult
    func requestSummary(_ recordingID: UUID) async -> WorkDecision {
        guard !isDemoMode else { return demoRefusal }
        guard store != nil, recordings.contains(where: { $0.id == recordingID }) else { return refuse(String(localized: "Session introuvable sur ce Mac.")) }
        let summarizer = summarizer
        if case .unavailable(let reason) = summarizer.availability {
            notifier.notify(.error(String(localized: "Synthèse : \(reason.localizedDescription)"), actions: [
                .navigate(String(localized: "Réglages"), to: .summarySettings)]))
            return .refused(.unavailable(reason.localizedDescription))
        }
        return await request(.summary(session: recordingID)) { [weak self] in await self?.runSummary(recordingID, with: summarizer) }
    }
    private func runSummary(_ recordingID: UUID, with summarizer: any Summarizer) async {
        defer { summaryProgress = nil }
        do {
            // Capture the revision only after pending UI edits have reached the store.
            // Otherwise the normal autosave can make our own snapshot look stale.
            await flush()
            try Task.checkCancellation()
            guard !hasUnsavedChanges else { return } // flush already exposes the save error.
            guard !isDemoMode, let item = recordings.first(where: { $0.id == recordingID }) else { throw SummaryFailure.stale }
            let result = try await summarizer.summarize(item) { value in
                await MainActor.run { self.summaryProgress = value }
            }
            try Task.checkCancellation()
            // Stale once the transcript or anything the summary read changed, here or in another process.
            do {
                try await sessionLibrary.apply(item.id, ifStillAt: item.transcriptVersion, where: { try SummaryPipeline.inputHash($0) == result.inputHash }) {
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
            } else {
                notifier.notify(.error(String(localized: "Synthèse : \(error.localizedDescription)"), actions: [
                    .perform(String(localized: "Réessayer")) { [weak self] in self?.retrySummary(recordingID) },
                    .navigate(String(localized: "Réglages"), to: .summarySettings)]))
            }
        }
    }
    func setMCPWrites(_ enabled: Bool) {
        guard !isDemoMode, let store else { return }
        Task {
            do { try await store.setMCPWritesEnabled(enabled); mcpWritesEnabled = enabled }
            catch { notifier.notify(.error(error.localizedDescription)) }
        }
    }
    func chooseExportDirectory() {
        guard !isDemoMode, let store else { return }
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
        guard await coordinator.snapshot.jobs(for: item.id).isEmpty else {
            notifier.notify(.info(String(localized: "Cette session est en cours de traitement. Annulez le traitement ou attendez sa fin pour la supprimer.")))
            return
        }
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
