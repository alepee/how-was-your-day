import AppKit
import AVFoundation
import Combine
import Foundation
import HWYDCore

@MainActor
final class AppModel: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var selectedID: UUID?
    @Published var search = ""
    @Published var kindFilter: SessionKind?
    @Published var activeTab: DetailTab = .transcript
    @Published var showSettings = false { didSet { if showSettings { showNewSession = false } } }
    @Published var settingsCategory: SettingsCategory = .general
    /// The latest error and notice. Each new value is also shown as a toast.
    @Published var errorMessage: String? { didSet { if bridgesToasts, let errorMessage { postToast(Toast(style: .error, message: errorMessage)) } } }
    @Published var notice: String? { didSet { if bridgesToasts, let notice { postToast(Toast(style: .info, message: notice)) } } }
    @Published private(set) var toasts: [Toast] = []
    private var toastTimers: [UUID: Task<Void, Never>] = [:]
    private var bridgesToasts = true
    /// The setup screen shown before a capture starts: kind and optional name.
    @Published var showNewSession = false
    @Published var newSessionKind: SessionKind = .adHoc {
        didSet { if persistPreferences && !isDemoMode { preferences.set(newSessionKind.rawValue, forKey: "newSession.kind") } }
    }
    @Published var newSessionTitle = ""
    @Published var isDemoMode = false
    @Published var isLoading = true
    @Published var activeCaptureID: UUID?
    @Published var elapsed: Double = 0
    /// The active capture is paused: no audio is captured and the clock is frozen.
    @Published var isCapturePaused = false
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var isStarting = false
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
    @Published var retentionHours: Int = UserDefaults.standard.object(forKey: "retentionHours") as? Int ?? 72 {
        didSet { if persistPreferences && !isDemoMode { preferences.set(retentionHours, forKey: "retentionHours") } }
    }
    @Published var mcpWritesEnabled = false
    @Published var exportDirectory = ""
    private var refreshTask: Task<Void, Never>?
    private var lastRefresh = Date.distantPast
    @Published var voiceBusy = false
    @Published var people: [VoicePerson] = []
    /// Confirmed voice waiting for the user to confirm its enrollment.
    @Published var enrollmentCandidateID: UUID?
    /// What each session added to a person's voice print, loaded on demand in the settings.
    @Published var voiceContributions: [UUID: [VoiceContribution]] = [:]
    private let voiceRunner = PipelineRunner()
    @Published var summaryID: UUID?
    @Published var summaryEnabled = UserDefaults.standard.bool(forKey: "summary.enabled")
    /// Starts the summary on its own once a session is ready: transcript done, every voice resolved.
    @Published var summaryAutomatic = false
    /// Transcript version of the last attempt per session, so a failure or a cancel is not retried automatically.
    private var automaticSummaryVersions: [UUID: Int] = [:]
    private var automaticSummaryTasks: [UUID: Task<Void, Never>] = [:]
    @Published var summaryEndpoint = UserDefaults.standard.string(forKey: "summary.endpoint") ?? "http://127.0.0.1:1234/v1"
    @Published var summaryModel = UserDefaults.standard.string(forKey: "summary.model") ?? ""
    @Published var summaryContextTokens = 32768
    @Published var summaryReasoningDisabled = false
    /// Choosing a hosted provider and storing its key is the opt-in: nothing is sent before both.
    @Published private(set) var summaryService: SummaryService = .local
    @Published var summaryRemoteModel = ""
    @Published private(set) var summaryKeyStored = false
    /// Models offered by the provider for the stored key; empty until fetched.
    @Published private(set) var summaryAvailableModels: [String] = []
    @Published private(set) var summaryModelsLoading = false
    private var summaryModelsTask: Task<Void, Never>?
    /// Agent mode: the command that starts an ACP agent, run through a login shell, and its working directory.
    @Published var summaryAgentCommand = ""
    @Published var summaryAgentDirectory = ""
    /// Commands of the known ACP agents installed on this Mac.
    @Published private(set) var summaryDetectedAgents: [String] = []
    @Published var summaryProgress: SummaryProgress?
    private var summaryTask: Task<Void, Never>?
    @Published var processingID: UUID?
    @Published var isInstallingDiarizer = false
    @Published var diarizationEnabled = UserDefaults.standard.bool(forKey: "diarizationEnabled") {
        didSet { if persistPreferences && !isDemoMode { preferences.set(diarizationEnabled, forKey: "diarizationEnabled") } }
    }
    @Published var isInstallingModel = false
    /// Language installing right now, shown next to its row.
    @Published var installingSpeechLocale: String?
    private let pipelineRunner = PipelineRunner()
    /// Session whose language should be chosen again, from a detection notice.
    @Published var languageChoiceID: UUID?
    /// System-wide shortcut that starts or ends a recording. Nil when the user cleared it.
    @Published var recordingShortcut: RecordingShortcut? = .standard {
        didSet {
            guard oldValue != recordingShortcut else { return }
            if persistPreferences { preferences.set(recordingShortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: RecordingShortcut.preferenceKey) }
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
    /// Known from Apple Speech, from an install done here, or from a transcript the model already produced.
    var speechModelReady: Bool {
        !installedSpeechLocales.isEmpty || preferences.bool(forKey: "models.speechInstalled") || recordings.contains { !$0.isDemo && $0.transcriptVersion > 0 && $0.transcription != nil }
    }
    /// Languages offered for a session: automatic detection, then the installed languages.
    var sessionLanguageChoices: [String] { [SpeechLanguage.automatic] + installedSpeechLocales }
    func refreshSpeechLanguages() {
        guard !isDemoMode else { return }
        Task {
            guard let data = try? await PipelineRunner.query(["languages"]),
                  let locales = try? JSONDecoder().decode(SpeechLocales.self, from: data) else { return }
            installedSpeechLocales = SpeechLanguage.oneLocalePerLanguage(locales.installed)
            supportedSpeechLocales = SpeechLanguage.oneLocalePerLanguage(locales.supported)
                .sorted { SpeechLanguage.displayName($0).localizedCompare(SpeechLanguage.displayName($1)) == .orderedAscending }
        }
    }
    /// The language a request uses: the session's choice, French for sessions recorded before the
    /// choice existed, and the fallback for a language uninstalled since.
    func transcriptionLocale(for item: Recording, override: String? = nil) -> (locale: String, candidates: [String]?, fallback: String?, installable: [String]?) {
        let requested = override ?? item.speechLanguage ?? SpeechLanguage.defaultLocale
        guard requested == SpeechLanguage.automatic else { return (requested, nil, nil, nil) }
        let installed = Set(installedSpeechLocales.map(SpeechLanguage.languageCode))
        return (requested, installedSpeechLocales, SpeechLanguage.fallback(installed: installedSpeechLocales),
                supportedSpeechLocales.filter { !installed.contains(SpeechLanguage.languageCode(of: $0)) })
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
            report(String(localized: "La langue de \(label(suggestion.source)) semble être : \(name). Ce modèle n’est pas installé."), actions: [
                ToastAction(title: String(localized: "Installer et retranscrire")) { [weak self] in self?.installSpeechModel(locale) { self?.transcribe(id, language: SpeechLanguage.automatic) } },
                ToastAction(title: String(localized: "Choisir la langue")) { [weak self] in self?.chooseLanguage(for: id) }], sticky: true)
        } else if let unknown = detections.first(where: { $0.unrecognized == true }) {
            report(String(localized: "La langue de \(label(unknown.source)) n’a pas été reconnue parmi les langues installées."), actions: [
                ToastAction(title: String(localized: "Choisir la langue")) { [weak self] in self?.chooseLanguage(for: id) }], sticky: true)
        }
    }
    var diarizerReady: Bool {
        preferences.bool(forKey: "models.diarizerInstalled") || recordings.contains { !$0.isDemo && $0.transcription?.diarizationEngine != nil }
    }
    var pipelineBusy: Bool { processingID != nil || isInstallingModel || isInstallingDiarizer || voiceBusy }
    var modelWorkBusy: Bool { pipelineBusy || summaryID != nil }
    @Published var savedAt: Date?
    @Published var hasUnsavedChanges = false
    @Published var appearancePreference: AppearancePreference = .system {
        didSet {
            if persistPreferences && !isDemoMode { preferences.set(appearancePreference.rawValue, forKey: "appearancePreference") }
            if appliesAppearance { NSApp.appearance = appearancePreference.appearance }
        }
    }
    private let preferences: UserDefaults
    private let appliesAppearance: Bool
    private let persistPreferences: Bool
    let calendar: CalendarIntegration
    let dataDirectory: URL
    var store: SessionStore?
    var showWindow: (() -> Void)?
    var openNotepad: (() -> Void)?
    private var dirtyIDs: Set<UUID> = []
    private var activeFlush: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var timer: Timer?
    private var captureStart: ContinuousClock.Instant?
    let player = SessionPlayback()
    private var capture: CaptureController?

    init(directory: URL? = nil, preview: Bool = false, preferences: UserDefaults = .standard, appliesAppearance: Bool = true, persistPreferences: Bool? = nil) {
        calendar = CalendarIntegration(preferences: preferences, allowed: directory == nil && !preview)
        self.preferences = preferences
        self.appliesAppearance = appliesAppearance
        self.persistPreferences = persistPreferences ?? (directory == nil && !preview)
        summaryEnabled = preferences.bool(forKey: "summary.enabled")
        summaryAutomatic = preferences.bool(forKey: "summary.automatic")
        summaryEndpoint = preferences.string(forKey: "summary.endpoint") ?? "http://127.0.0.1:1234/v1"
        summaryModel = preferences.string(forKey: "summary.model") ?? ""
        summaryContextTokens = preferences.integer(forKey: "summary.contextTokens") == 0 ? 32768 : preferences.integer(forKey: "summary.contextTokens")
        summaryReasoningDisabled = preferences.bool(forKey: "summary.reasoningDisabled")
        summaryService = SummaryService(rawValue: preferences.string(forKey: "summary.service") ?? "") ?? .local
        newSessionKind = SessionKind(rawValue: preferences.string(forKey: "newSession.kind") ?? "") ?? .adHoc
        if let data = preferences.data(forKey: RecordingShortcut.preferenceKey) {
            recordingShortcut = data.isEmpty ? nil : (try? JSONDecoder().decode(RecordingShortcut.self, from: data)) ?? .standard
        }
        summaryAgentCommand = preferences.string(forKey: "summary.agent.command") ?? "claude-agent-acp"
        summaryAgentDirectory = preferences.string(forKey: "summary.agent.directory") ?? "~"
        appearancePreference = AppearancePreference(rawValue: preferences.string(forKey: "appearancePreference") ?? "") ?? .system
        dataDirectory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HWYD")
        if appliesAppearance { NSApp.appearance = appearancePreference.appearance }
        if preview {
            recordings = DemoContent.recordings(); isDemoMode = true; isLoading = false
            installedSpeechLocales = ["fr-FR", "en-US"]; supportedSpeechLocales = ["de-DE", "en-US", "es-ES", "fr-FR"]
        } else {
            do { store = try SessionStore(directory: dataDirectory) }
            catch { errorMessage = String(localized: "Impossible d’ouvrir les données locales : \(error.localizedDescription)"); isLoading = false }
        }
        loadRemoteSummarySettings()
    }
    func load() async {
        guard let store else { return }
        refreshSpeechLanguages()
        do {
            let count = try await store.recoverInterrupted()
            recordings = try await store.all()
            people = try await store.people()
            mcpWritesEnabled = try await store.setting("mcp_writes_enabled") == "true"
            exportDirectory = try await store.setting("export_directory") ?? ""
            try await store.publishPending()
            for item in recordings where item.transcriptState == .pending {
                update(item.id) { $0.transcriptState = .failed }
            }
            if count > 0 { notice = String(localized: "\(count) session(s) interrompue(s) retrouvée(s). Vos notes sont conservées.") }
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
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
    func select(_ item: Recording) { showSettings = false; showNewSession = false; stopPlayback(); selectedID = item.id; activeTab = .transcript; playbackTime = 0; playback.activeSegmentIDs = []; mutedTracks = []; soloTracks = []; trackEnvelopes = [:] }
    func library() { showSettings = false; showNewSession = false; stopPlayback(); selectedID = nil; search = "" }
    func enterDemo() {
        guard activeCaptureID == nil, !modelWorkBusy, !hasUnsavedChanges else { return }
        calendar.suspend()
        stopPlayback(); isDemoMode = true; selectedID = nil; recordings = DemoContent.recordings(); startTicker()
    }
    func leaveDemo() {
        stopPlayback(); activeCaptureID = nil; captureStart = nil; isDemoMode = false; selectedID = nil
        Task { await load(); calendar.start() }
    }
    func update(_ id: UUID, _ edit: (inout Recording) -> Void) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        edit(&recordings[index])
        if !isDemoMode { dirtyIDs.insert(id); hasUnsavedChanges = true; scheduleSave(); scheduleAutomaticSummary(id) }
    }
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            await self.flush()
            self.saveTask = nil
        }
    }
    func flush() async {
        if let activeFlush { await activeFlush.value; return }
        let task = Task { await self.drainChanges() }
        activeFlush = task
        await task.value
        activeFlush = nil
    }
    private func drainChanges() async {
        guard let store, !isDemoMode else { return }
        while let id = dirtyIDs.first {
            dirtyIDs.remove(id)
            guard let item = recordings.first(where: { $0.id == id }) else { continue }
            do {
                let saved = try await store.save(item)
                if let index = recordings.firstIndex(where: { $0.id == id }) { recordings[index].revision = saved.revision; recordings[index].notesVersion = saved.notesVersion; recordings[index].summaryVersion = saved.summaryVersion }
                savedAt = Date()
            } catch {
                dirtyIDs.insert(id)
                report(String(localized: "Les dernières modifications ne sont pas enregistrées : \(error.localizedDescription)"), style: .error,
                       actions: [ToastAction(title: String(localized: "Réessayer")) { [weak self] in self?.retrySave() }])
                hasUnsavedChanges = true; return
            }
        }
        hasUnsavedChanges = false
        do { try await store.publishPending() } catch { notice = String(localized: "Export différé : \(error.localizedDescription)") }
    }
    func retrySave() { errorMessage = nil; scheduleSave() }
    func addTimestamp() {
        guard let id = activeCaptureID else { return }
        update(id) { $0.noteEntries.append(.init(offset: elapsed)) }
    }
    func beginSpeakerEdit(_ speaker: Speaker) { editingSpeakerID = speaker.id; speakerName = speaker.confirmed || speaker.proposedIdentity != nil ? speaker.label : "" }
    /// Names the voice if needed, then adds a sample of it to the person's voice print. The
    /// channel follows the voice's track. Only an explicit request from the user leads here.
    func rememberSpeaker(name: String, speakerID: UUID) {
        guard let id = selectedID, !voiceEditingLocked, !pipelineBusy, var item = selected,
              let speaker = item.speakers.first(where: { $0.id == speakerID }) else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { errorMessage = String(localized: "Le nom doit contenir entre 1 et 120 caractères."); return }
        var person = people.first { $0.id == speaker.personID && $0.name == name }
            ?? people.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame } ?? VoicePerson(name: name)
        guard !person.opposed else { errorMessage = String(localized: "\(person.name) est exclue de la reconnaissance. Levez l’exclusion dans Réglages › Audio et voix."); return }
        person.enrollmentRequestedAt = Date()
        if !(speaker.confirmed && speaker.label == name) {
            do { try item.renameSpeaker(speakerID, to: name); update(id) { $0 = item } } catch { errorMessage = error.localizedDescription; return }
        }
        editingSpeakerID = nil
        runVoice(command: "enroll-voice", speakerID: speakerID, person: person)
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
            let proposal = item.speakers.first { $0.id == speakerID }?.proposedIdentity
            try item.renameSpeaker(speakerID, to: name)
            if let proposal, let person = people.first(where: { $0.id == proposal.personID && $0.recognitionEnabled }), person.name == name,
               let index = item.speakers.firstIndex(where: { $0.id == speakerID }) { item.speakers[index].personID = person.id }
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
            notice = String(localized: "Attribution corrigée pour ce passage uniquement.")
        } catch { errorMessage = error.localizedDescription }
    }
    @discardableResult
    func splitSegment(_ segment: TranscriptSegment, beforeWord index: Int, recordingID: UUID) -> Bool {
        guard recordingID != processingID,
              var item = recordings.first(where: { $0.id == recordingID }), item.state != .recording else { return false }
        do {
            guard item.segments.first(where: { $0.id == segment.id }) == segment else { throw StoreError.conflict }
            try item.splitSegment(segment.id, beforeWord: index)
            update(recordingID) { $0 = item }
            notice = String(localized: "Passage découpé. Vous pouvez corriger la voix de chaque partie.")
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    /// Records the event; `openLink` also opens its video link first.
    func joinMeeting(_ event: CalendarContext, openLink: Bool = true) {
        showWindow?()
        guard !isDemoMode, activeCaptureID == nil, !isStarting else {
            notice = String(localized: "Une capture est déjà en cours."); return
        }
        if let existing = recordings.first(where: { $0.calendarContext?.id == event.id }) {
            select(existing); notice = String(localized: "Cette réunion possède déjà une session."); return
        }
        if openLink, let url = event.meetingURL { NSWorkspace.shared.open(url) }
        startCapture(meeting: event)
    }
    /// Pauses or resumes the active capture without ending the session.
    /// Paused time is left out of the recording timeline, so notes stay aligned with the audio.
    func toggleCapturePause() {
        guard activeCaptureID != nil else { return }
        if isCapturePaused {
            if let capture {
                do { try capture.resume() } catch { errorMessage = error.localizedDescription; return }
            }
            captureStart = ContinuousClock.now.advanced(by: .milliseconds(-Int64((elapsed * 1000).rounded())))
            isCapturePaused = false
            notice = nil
        } else {
            tick()
            capture?.pause()
            captureStart = nil; micLevel = 0; systemLevel = 0
            isCapturePaused = true
        }
    }
    // MARK: Toasts

    func postToast(_ toast: Toast) {
        // The same message twice replaces the first one instead of stacking.
        toasts.removeAll { $0.message == toast.message && $0.style == toast.style }
        toasts.append(toast)
        while toasts.count > 4, let oldest = toasts.firstIndex(where: { !$0.staysOnScreen }) ?? toasts.indices.first {
            dismissToast(toasts[oldest].id)
        }
        scheduleDismissal(toast)
        AccessibilityNotification.Announcement(toast.message).post()
    }
    /// Sets the matching message property without a second, plain toast.
    func report(_ message: String, style: Toast.Style = .info, actions: [ToastAction] = [], sticky: Bool = false, optional: Bool = false) {
        bridgesToasts = false
        if style == .error { errorMessage = message } else { notice = message }
        bridgesToasts = true
        postToast(Toast(style: style, message: message, actions: actions, sticky: sticky, optional: optional))
    }
    func dismissToast(_ id: UUID) {
        toastTimers.removeValue(forKey: id)?.cancel()
        toasts.removeAll { $0.id == id }
    }
    func runToastAction(_ action: ToastAction, of toast: Toast) {
        dismissToast(toast.id)
        action.run()
    }
    /// Hovering keeps a toast on screen; leaving it gives a short delay before it goes.
    func holdToast(_ id: UUID, _ held: Bool) {
        guard let toast = toasts.first(where: { $0.id == id }), !toast.staysOnScreen else { return }
        toastTimers.removeValue(forKey: id)?.cancel()
        if !held { scheduleDismissal(toast, after: .seconds(2)) }
    }
    private func scheduleDismissal(_ toast: Toast, after delay: Duration? = nil) {
        guard !toast.staysOnScreen else { return }
        toastTimers[toast.id] = Task { [weak self] in
            try? await Task.sleep(for: delay ?? toast.lifetime)
            guard !Task.isCancelled else { return }
            self?.toasts.removeAll { $0.id == toast.id }
            self?.toastTimers[toast.id] = nil
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
    func startCapture(meeting: CalendarContext? = nil, kind: SessionKind? = nil, title: String? = nil, language: String? = nil, reveal: Bool = true) {
        guard activeCaptureID == nil, !isStarting else { if reveal { showWindow?() }; return }
        let kind = meeting == nil ? (kind ?? .adHoc) : .meeting
        let typed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let time = Date().formatted(date: .omitted, time: .shortened)
        let sessionTitle = !typed.isEmpty ? typed : meeting?.title ?? (kind == .adHoc ? String(localized: "Session du \(time)") : String(localized: "\(kind.label) du \(time)"))
        let language = language ?? SpeechLanguage.automatic
        showSettings = false; showNewSession = false
        startTicker(); stopPlayback(); isStarting = true
        Task {
            defer { isStarting = false }
            let id = UUID()
            if isDemoMode {
                let item = Recording(id: id, title: sessionTitle, kind: kind, state: .recording, isDemo: true)
                recordings.insert(item, at: 0); activeCaptureID = id; selectedID = id
                elapsed = 0; captureStart = .now; if reveal { showWindow?() }; return
            }
            guard store != nil else { errorMessage = String(localized: "Le store local n’est pas disponible."); return }
            do {
                let controller = CaptureController()
                try await controller.start(id: id, directory: dataDirectory)
                capture = controller
                var item = Recording(id: id, title: sessionTitle, kind: kind, state: .recording)
                item.calendarContext = meeting; item.speechLanguage = language
                recordings.insert(item, at: 0); activeCaptureID = id; selectedID = id
                elapsed = 0; captureStart = .now; dirtyIDs.insert(id)
                await flush(); if reveal { showWindow?() }
            } catch { errorMessage = error.localizedDescription; if !reveal { showWindow?() } }
        }
    }
    func stopCapture(reveal: Bool = true) {
        guard let id = activeCaptureID else { return }
        let duration = elapsed
        let chunks = capture?.stop() ?? []
        let finalizationError = capture?.finalizationError
        capture = nil; captureStart = nil; activeCaptureID = nil; micLevel = 0; systemLevel = 0; isCapturePaused = false
        update(id) { $0.duration = duration; $0.state = finalizationError == nil ? .sealed : .interrupted; $0.audioChunks = chunks }
        if let finalizationError { errorMessage = finalizationError }
        selectedID = id; activeTab = .notes
        notice = isDemoMode ? String(localized: "Simulation terminée. Les notes restent disponibles.") : (chunks.isEmpty ? String(localized: "Aucun audio reçu. Vos notes sont conservées.") : String(localized: "Audio et notes conservés. La transcription locale va démarrer."))
        if reveal || finalizationError != nil { showWindow?() }
        if !isDemoMode, !chunks.isEmpty {
            if modelWorkBusy { notice = String(localized: "Audio conservé. Un traitement est déjà en cours ; lancez la transcription depuis cette session ensuite.") }
            else { transcribe(id) }
        }
    }
    func cancelProcessing() { pipelineRunner.cancel(); voiceRunner.cancel() }
    func installSpeechModel(_ locale: String, then completion: (() -> Void)? = nil) {
        guard !modelWorkBusy, !isDemoMode else { return }
        pipelineRunner.prepare()
        isInstallingModel = true; installingSpeechLocale = locale
        Task {
            defer { isInstallingModel = false; installingSpeechLocale = nil; refreshSpeechLanguages() }
            do {
                let directory = dataDirectory.appendingPathComponent("jobs")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try await pipelineRunner.run(arguments: ["install-model", locale], log: directory.appendingPathComponent("install-model.log"))
                if persistPreferences { preferences.set(true, forKey: "models.speechInstalled") }
                notice = String(localized: "Langue installée : \(SpeechLanguage.displayName(locale)). La transcription reste locale.")
                if let completion { isInstallingModel = false; installingSpeechLocale = nil; completion() }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func installDiarizer() {
        guard !modelWorkBusy, !isDemoMode else { return }
        pipelineRunner.prepare(); isInstallingDiarizer = true
        Task {
            defer { isInstallingDiarizer = false }
            do {
                let directory = dataDirectory.appendingPathComponent("jobs")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try await pipelineRunner.run(arguments: ["install-diarizer", dataDirectory.path], log: directory.appendingPathComponent("install-diarizer.log"))
                if persistPreferences { preferences.set(true, forKey: "models.diarizerInstalled") }
                diarizationEnabled = true
                notice = String(localized: "Séparation des voix activée pour les prochains traitements.")
            } catch { errorMessage = String(localized: "Installation des voix : \(error.localizedDescription)") }
        }
    }
    /// `language` replaces the session's language for this run and becomes its new choice.
    func transcribe(_ id: UUID, language: String? = nil) {
        guard !isDemoMode, !modelWorkBusy, let item = recordings.first(where: { $0.id == id }), item.state != .recording, !item.audioChunks.isEmpty else { return }
        pipelineRunner.prepare()
        processingID = id
        let originalVersion = item.transcriptVersion
        update(id) { $0.transcriptState = .pending }
        Task {
            defer { processingID = nil }
            do {
                await flush()
                guard !hasUnsavedChanges else { throw PipelineFailure(message: String(localized: "Sauvegardez les modifications avant de transcrire.")) }
                let job = dataDirectory.appendingPathComponent("jobs/\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let input = job.appendingPathComponent("request.json"), output = job.appendingPathComponent("result.json")
                if let data = try? await PipelineRunner.query(["languages"]),
                   let locales = try? JSONDecoder().decode(SpeechLocales.self, from: data) {
                    installedSpeechLocales = SpeechLanguage.oneLocalePerLanguage(locales.installed)
                    supportedSpeechLocales = SpeechLanguage.oneLocalePerLanguage(locales.supported)
                }
                let choice = transcriptionLocale(for: item, override: language)
                let request = TranscriptionRequest(recordingID: id, locale: choice.locale, chunks: item.audioChunks, diarize: diarizationEnabled,
                                                   candidateLocales: choice.candidates, fallbackLocale: choice.fallback, installableLocales: choice.installable)
                try JSONEncoder().encode(request).write(to: input, options: .atomic)
                try await pipelineRunner.run(arguments: ["transcribe", dataDirectory.path, input.path, output.path], log: job.appendingPathComponent("pipeline.log"))
                let result = try JSONDecoder().decode(TranscriptionResult.self, from: Data(contentsOf: output))
                guard var latest = recordings.first(where: { $0.id == id }), latest.transcriptVersion == originalVersion else { throw TranscriptionError.staleResult }
                try latest.applyTranscription(result)
                if let language { latest.speechLanguage = language }
                update(id) { $0 = latest }
                await flush()
                if !hasUnsavedChanges { try? FileManager.default.removeItem(at: job) }
                notice = result.segments.isEmpty ? String(localized: "Traitement terminé : aucune parole reconnue.") : (result.diarizationEngine == nil ? String(localized: "Transcript disponible. Les voix ne sont pas séparées.") : String(localized: "Transcript disponible. Les voix détectées peuvent être nommées dans cette session."))
                if let warning = result.identityWarning { notice = String(localized: "Transcript disponible.") + " " + warning }
                if let detections = result.languageDetection { reportLanguageFindings(detections, id: id) }
            } catch {
                update(id) { $0.transcriptState = .failed }
                report(String(localized: "Transcription : \(error.localizedDescription)"), style: .error,
                       actions: [ToastAction(title: String(localized: "Réessayer")) { [weak self] in self?.transcribe(id, language: language) }])
                await flush()
            }
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
        if Date().timeIntervalSince(lastRefresh) > 3, refreshTask == nil, !isDemoMode, !hasUnsavedChanges, activeCaptureID == nil, !pipelineBusy, summaryID == nil, let store {
            lastRefresh = Date()
            refreshTask = Task {
                defer { refreshTask = nil }
                if let revisions = try? await store.recordingRevisions(),
                   revisions != Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0.revision) }),
                   let latest = try? await store.all(), !hasUnsavedChanges, activeCaptureID == nil, !pipelineBusy, summaryID == nil { recordings = latest }
            }
        }
        if let captureStart {
            let parts = captureStart.duration(to: .now).components
            elapsed = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            if isDemoMode {
                micLevel = Float((sin(elapsed * 2.2) + 1) * 0.3 + 0.05)
                systemLevel = Float((sin(elapsed * 1.6) + 1) * 0.16)
            } else if let capture {
                micLevel = capture.micLevel; systemLevel = capture.systemLevel
                if let failure = capture.failure { let id = activeCaptureID; stopCapture(); if let id { update(id) { $0.state = .interrupted } }; errorMessage = failure }
            }
        }
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
            notice = String(localized: "Aucun fichier audio disponible pour cette session."); return
        }
        stopPlayback()
        do {
            playbackTime = min(max(0, time), item.duration)
            try player.start(chunks: item.audioChunks, store: store, at: playbackTime, duration: item.duration)
            applyTrackMix(); isPlaying = true; playback.generation += 1; updatePlaybackFocus()
        } catch { errorMessage = String(localized: "Lecture impossible : \(error.localizedDescription)") }
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
    /// Runs a voice command in the helper, the only process that reads the keychain.
    func runVoice(command: String, speakerID: UUID? = nil, person: VoicePerson? = nil, personID: UUID? = nil, sourceRecordingID: UUID? = nil,
                  then: (@MainActor () async throws -> Void)? = nil) {
        guard !isDemoMode, !modelWorkBusy, let store else { return }
        let item = command == "identify-voices" || command == "enroll-voice" ? selected ?? Recording(title: "Gestion des voix") : Recording(title: "Gestion des voix") // l10n:ignore
        let personID = person?.id ?? personID
        let name = person?.name ?? people.first { $0.id == personID }?.name ?? ""
        voiceBusy = true; voiceRunner.prepare()
        Task {
            defer { voiceBusy = false }
            let folder = dataDirectory.appendingPathComponent("jobs/voice-" + UUID().uuidString)
            do {
                if let person { try await store.savePerson(person); people = try await store.people() }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: folder) }
                let request = folder.appendingPathComponent("request.json"), result = folder.appendingPathComponent("result.json")
                try JSONEncoder().encode(VoiceJob(recording: item, speakerID: speakerID, personID: personID, sourceRecordingID: sourceRecordingID)).write(to: request, options: .atomic)
                try await voiceRunner.run(arguments: [command, dataDirectory.path, request.path, result.path], log: folder.appendingPathComponent("log.txt"))
                let output = try Data(contentsOf: result)
                people = try await store.people()
                switch command {
                case "voice-sources":
                    if let personID { voiceContributions[personID] = try JSONDecoder().decode([VoiceContribution].self, from: output) }
                case "forget-voice":
                    if let personID { voiceContributions[personID] = nil }
                    notice = person?.opposed == true ? String(localized: "Empreintes de \(name) supprimées. Opposition enregistrée.")
                        : String(localized: "Empreinte de \(name) effacée. Sa voix ne sera plus reconnue avant une nouvelle mémorisation.")
                case "forget-voice-source":
                    if let personID { voiceContributions[personID]?.removeAll { $0.recordingID == sourceRecordingID } }
                    notice = String(localized: "Apport retiré de l’empreinte de \(name).")
                default:
                    let matches = try JSONDecoder().decode([String: VoiceMatch].self, from: output)
                    // A transcript edited meanwhile keeps the user's version.
                    guard recordings.first(where: { $0.id == item.id })?.transcriptVersion == item.transcriptVersion else {
                        notice = command == "enroll-voice" ? String(localized: "Voix de \(name) mémorisée.") : String(localized: "La session a changé pendant la reconnaissance. Aucune proposition appliquée.")
                        return
                    }
                    var proposed = 0
                    update(item.id) { current in
                        var changed = false
                        for index in current.speakers.indices {
                            let speaker = current.speakers[index]
                            if command == "enroll-voice", speaker.id == speakerID, let person {
                                current.speakers[index].personID = person.id; current.speakers[index].label = person.name
                                current.speakers[index].confirmed = true; current.speakers[index].proposedIdentity = nil
                                changed = true
                            } else if !speaker.confirmed, !speaker.ignored, let match = matches[speaker.id.uuidString],
                                      let known = people.first(where: { $0.id == match.personID }) {
                                current.speakers[index].proposedIdentity = match; current.speakers[index].label = known.name
                                proposed += 1
                            }
                        }
                        if changed { current.transcriptVersion += 1; current.summary = nil }
                    }
                    await flush()
                    let found = proposed == 0 ? nil : proposed == 1 ? String(localized: "Une autre voix ressemble à une personne connue, à confirmer.")
                        : String(localized: "\(proposed) autres voix ressemblent à des personnes connues, à confirmer.")
                    notice = command == "enroll-voice" ? [String(localized: "Voix de \(name) mémorisée."), found].compactMap { $0 }.joined(separator: " ")
                        : String(localized: "\(proposed) correspondance(s) proposée(s), à confirmer.")
                }
                try await then?()
            } catch { errorMessage = String(localized: "Identité vocale : \(error.localizedDescription)") }
        }
    }
    /// Ends an opposition. Any sample left by an interrupted erasure goes first, so recognition
    /// resumes only after a new enrollment.
    func liftOpposition(_ person: VoicePerson) {
        guard let store else { return }
        runVoice(command: "forget-voice", personID: person.id) { [weak self] in
            try await store.liftOpposition(person.id)
            self?.people = try await store.people()
            self?.notice = String(localized: "\(person.name) n’est plus exclue. Mémorisez sa voix depuis une session pour la reconnaître à nouveau.")
        }
    }
    func saveSummarySettings() {
        guard !isDemoMode, persistPreferences else { return }
        preferences.set(summaryEnabled, forKey: "summary.enabled")
        preferences.set(summaryAutomatic, forKey: "summary.automatic")
        preferences.set(summaryEndpoint, forKey: "summary.endpoint")
        preferences.set(summaryModel, forKey: "summary.model")
        preferences.set(summaryContextTokens, forKey: "summary.contextTokens")
        preferences.set(summaryReasoningDisabled, forKey: "summary.reasoningDisabled")
        preferences.set(summaryService.rawValue, forKey: "summary.service")
        preferences.set(summaryAgentCommand, forKey: "summary.agent.command")
        preferences.set(summaryAgentDirectory, forKey: "summary.agent.directory")
        if summaryService.isRemote {
            preferences.set(summaryRemoteModel, forKey: "summary.model." + summaryService.rawValue)
        }
    }
    private func loadRemoteSummarySettings() {
        let service = summaryService
        summaryRemoteModel = service.isRemote ? preferences.string(forKey: "summary.model." + service.rawValue) ?? service.defaultModel : ""
        summaryModelsTask?.cancel(); summaryModelsTask = nil
        summaryAvailableModels = []; summaryModelsLoading = false
        // Previews, demos and tests never touch the keychain.
        summaryKeyStored = service.isRemote && persistPreferences && SummaryKeychain.hasKey(for: service)
    }
    func selectSummaryService(_ service: SummaryService) {
        guard service != summaryService else { return }
        saveSummarySettings()
        summaryService = service
        loadRemoteSummarySettings()
        saveSummarySettings()
    }
    /// Checks the key by listing the provider's models, then stores it. A rejected key is not stored;
    /// a network failure still stores it, since the check can be repeated later.
    func saveSummaryKey(_ key: String) {
        let service = summaryService
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard service.isRemote, !isDemoMode, persistPreferences, !key.isEmpty else { return }
        summaryModelsTask?.cancel()
        summaryModelsLoading = true
        summaryModelsTask = Task {
            defer { if summaryService == service { summaryModelsLoading = false } }
            var models: [String] = []
            do { models = try await SummaryModelCatalog.models(service: service, apiKey: key) }
            catch SummaryFailure.remoteRejected(let name, let status, let detail) where status == 401 || status == 403 {
                errorMessage = SummaryFailure.remoteRejected(service: name, status: status, detail: detail).localizedDescription + " " + String(localized: "La clé n’a pas été enregistrée.")
                return
            } catch {
                if Task.isCancelled { return }
                notice = String(localized: "Liste des modèles indisponible : \(error.localizedDescription)")
            }
            guard !Task.isCancelled else { return }
            do { try SummaryKeychain.setKey(key, for: service) }
            catch { errorMessage = String(localized: "Clé API : \(error.localizedDescription)"); return }
            guard summaryService == service else { return }
            summaryKeyStored = true
            applyAvailableModels(models)
        }
    }
    /// Fetches the provider's models for the stored key. Called when the settings show a hosted provider.
    func refreshSummaryModels() {
        let service = summaryService
        guard service.isRemote, summaryKeyStored, !isDemoMode, persistPreferences, !summaryModelsLoading else { return }
        summaryModelsLoading = true
        summaryModelsTask = Task {
            defer { if summaryService == service { summaryModelsLoading = false } }
            do {
                guard let key = try SummaryKeychain.key(for: service) else { return }
                let models = try await SummaryModelCatalog.models(service: service, apiKey: key)
                if !Task.isCancelled, summaryService == service { applyAvailableModels(models) }
            } catch {
                if !Task.isCancelled, summaryService == service { errorMessage = String(localized: "Modèles \(service.displayName) : \(error.localizedDescription)") }
            }
        }
    }
    private func applyAvailableModels(_ models: [String]) {
        summaryAvailableModels = models
        // A suggested default this account does not offer is cleared so the user picks from the list.
        // A model the user typed or chose is never replaced.
        if !models.isEmpty, summaryRemoteModel == summaryService.defaultModel, !models.contains(summaryRemoteModel) {
            summaryRemoteModel = ""
            saveSummarySettings()
        }
    }
    /// Looks for the known ACP agents through a login shell, as the agent itself will be launched.
    func detectSummaryAgents() {
        guard !isDemoMode, persistPreferences, summaryDetectedAgents.isEmpty else { return }
        Task.detached(priority: .utility) {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", ACPAgentPreset.all.map { "command -v \($0.executable) >/dev/null 2>&1 && echo \($0.executable)" }.joined(separator: "; ")]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
            let found = Set(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init))
            await MainActor.run { self.summaryDetectedAgents = ACPAgentPreset.all.filter { found.contains($0.executable) }.map(\.command) }
        }
    }
    func chooseSummaryAgentDirectory() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = String(localized: "Utiliser ce dossier"); panel.message = String(localized: "L’agent démarre dans ce dossier et y trouve son contexte (instructions, mémoire, notes).")
        if panel.runModal() == .OK, let url = panel.url {
            summaryAgentDirectory = (url.path as NSString).abbreviatingWithTildeInPath; saveSummarySettings()
        }
    }
    func removeSummaryKey() {
        guard summaryService.isRemote, !isDemoMode, persistPreferences else { return }
        summaryModelsTask?.cancel(); summaryAvailableModels = []; summaryModelsLoading = false
        do { try SummaryKeychain.removeKey(for: summaryService); summaryKeyStored = false; notice = String(localized: "Clé \(summaryService.displayName) supprimée.") }
        catch { errorMessage = String(localized: "Clé API : \(error.localizedDescription)") }
    }
    func cancelSummary() { summaryTask?.cancel() }
    /// Delay after the last change before an automatic summary starts, so a correction can still be undone.
    var automaticSummaryDelay: Duration = .seconds(10)
    /// Real sessions only: tests, previews and demo never start a summary on their own.
    private var automaticSummaryAllowed: Bool {
        summaryAutomatic && summaryEnabled && persistPreferences && !isDemoMode && store != nil
            && (!summaryService.isRemote || summaryKeyStored)
    }
    /// Waits for the session to stay ready and unchanged, then starts its summary once per transcript version.
    private func scheduleAutomaticSummary(_ id: UUID) {
        guard automaticSummaryAllowed, let item = recordings.first(where: { $0.id == id }), item.isReadyForSummary,
              automaticSummaryVersions[id] != item.transcriptVersion else { return }
        let version = item.transcriptVersion
        automaticSummaryTasks[id]?.cancel()
        automaticSummaryTasks[id] = Task { [weak self] in
            guard let delay = self?.automaticSummaryDelay else { return }
            try? await Task.sleep(for: delay)
            // Another model job (transcription, voices, a summary) finishes first.
            while let self, !Task.isCancelled, self.modelWorkBusy || self.hasUnsavedChanges { try? await Task.sleep(for: .seconds(2)) }
            guard let self, !Task.isCancelled else { return }
            self.automaticSummaryTasks[id] = nil
            guard self.automaticSummaryAllowed, let current = self.recordings.first(where: { $0.id == id }),
                  current.transcriptVersion == version, current.isReadyForSummary,
                  self.automaticSummaryVersions[id] != version else { return }
            self.generateSummary(recordingID: id, automatic: true)
        }
    }
    func generateSummary() {
        guard let id = selected?.id else { return }
        generateSummary(recordingID: id)
    }
    func generateSummary(recordingID: UUID, automatic: Bool = false) {
        guard summaryEnabled, !modelWorkBusy, !isDemoMode, let store,
              let version = recordings.first(where: { $0.id == recordingID })?.transcriptVersion else { return }
        automaticSummaryVersions[recordingID] = version
        summaryID = recordingID
        if automatic {
            let title = recordings.first { $0.id == recordingID }?.title ?? ""
            report(String(localized: "Synthèse automatique lancée : \(title)"),
                   actions: [ToastAction(title: String(localized: "Annuler")) { [weak self] in
                       guard self?.summaryID == recordingID else { return }
                       self?.cancelSummary()
                   }])
        }
        summaryTask = Task {
            defer { summaryID = nil; summaryTask = nil; summaryProgress = nil }
            do {
                // Capture the revision only after pending UI edits have reached the store.
                // Otherwise the normal autosave can make our own snapshot look stale.
                await flush()
                try Task.checkCancellation()
                guard !hasUnsavedChanges else { return } // flush already exposes the save error.
                guard !isDemoMode, let item = recordings.first(where: { $0.id == recordingID }) else { throw SummaryFailure.stale }
                let service = summaryService
                let result: SummaryProvenance
                if service == .agent {
                    let workingDirectory = URL(fileURLWithPath: (summaryAgentDirectory as NSString).expandingTildeInPath, isDirectory: true)
                    result = try await ACPSummaryAgent.run(item, command: summaryAgentCommand, workingDirectory: workingDirectory,
                        mcpExecutable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/hwyd-mcp"), storeDirectory: dataDirectory) { value in
                            await MainActor.run { self.summaryProgress = value }
                        }
                } else {
                let provider: any LLMProvider, modelName: String, identity: String, inputLimit: Int
                if service.isRemote {
                    guard persistPreferences, let key = try SummaryKeychain.key(for: service) else { throw SummaryFailure.apiKeyMissing(service.displayName) }
                    let remote = try RemoteLLMProvider(service: service, model: summaryRemoteModel, apiKey: key)
                    provider = remote; modelName = remote.model; identity = remote.identity; inputLimit = remote.requestCharacterCeiling
                } else {
                    guard let url = URL(string: summaryEndpoint) else { throw SummaryFailure.invalidEndpoint }
                    provider = try LocalLLMProvider(endpoint: url, model: summaryModel,
                        reasoningEffort: summaryReasoningDisabled ? "none" : nil)
                    modelName = summaryModel
                    identity = url.absoluteString + "|reasoning=" + (summaryReasoningDisabled ? "none" : "server-default")
                    inputLimit = max(12_000, (summaryContextTokens - 10_000) * 2)
                }
                result = try await SummaryPipeline.run(item, provider: provider, model: modelName,
                    inputCharacterLimit: inputLimit,
                    cacheDirectory: dataDirectory.appendingPathComponent("cache/summaries/" + item.id.uuidString), reuseCache: item.summary == nil,
                    providerIdentity: identity) { value in
                        await MainActor.run { self.summaryProgress = value }
                    }
                }
                try Task.checkCancellation()
                guard let latest = recordings.first(where: { $0.id == item.id }), latest.transcriptVersion == item.transcriptVersion,
                    try SummaryPipeline.inputHash(latest) == result.inputHash else { throw SummaryFailure.stale }
                let persisted = try await store.recording(item.id)
                guard persisted.revision == item.revision else { throw SummaryFailure.stale }
                update(item.id) { $0.summary = result.structured.markdown; $0.summaryProvenance = result }
                await flush()
                // A long run (agents take minutes) may finish while another screen is open.
                let showsSummary = selectedID == item.id && activeTab == .summary && !showSettings
                report(String(localized: "Synthèse prête : \(item.title)"), style: .success,
                       actions: showsSummary ? [] : [ToastAction(title: String(localized: "Afficher")) { [weak self] in
                           guard let self, let latest = self.recordings.first(where: { $0.id == item.id }) else { return }
                           self.select(latest); self.activeTab = .summary
                       }])
            } catch {
                if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                    notice = String(localized: "Synthèse annulée.")
                } else if automatic, case SummaryFailure.stale = error {
                    // The session changed during the run: start again once it is ready and quiet.
                    automaticSummaryVersions[recordingID] = nil
                    scheduleAutomaticSummary(recordingID)
                } else {
                    report(String(localized: "Synthèse : \(error.localizedDescription)"), style: .error, actions: [
                        ToastAction(title: String(localized: "Réessayer")) { [weak self] in
                            guard let self, let item = self.recordings.first(where: { $0.id == recordingID }) else { return }
                            self.select(item); self.activeTab = .summary; self.generateSummary()
                        },
                        ToastAction(title: String(localized: "Réglages")) { [weak self] in self?.settingsCategory = .summary; self?.showSettings = true }])
                }
            }
        }
    }
    func setMCPWrites(_ enabled: Bool) {
        guard !isDemoMode, let store else { return }
        Task {
            do { try await store.setSetting("mcp_writes_enabled", value: enabled ? "true" : "false"); mcpWritesEnabled = enabled }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func chooseExportDirectory() {
        guard !isDemoMode, let store else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = String(localized: "Utiliser ce dossier"); panel.message = String(localized: "Les sessions sauvegardées seront publiées ici en Markdown et JSON.")
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await store.setSetting("export_directory", value: url.path); exportDirectory = url.path
                    await flush()
                    try await store.publishPending()
                    notice = String(localized: "Dossier de publication configuré.")
                } catch { errorMessage = String(localized: "Export différé : \(error.localizedDescription)") }
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
                    try SessionExporter.export(current, to: url); notice = String(localized: "Session exportée en Markdown et JSON."); NSWorkspace.shared.open(url)
                } catch { errorMessage = String(localized: "Export impossible : \(error.localizedDescription)") }
            }
        }
    }
    func deleteConfirmed() {
        guard let item = deleteCandidate, item.id != activeCaptureID, item.id != processingID else { return }
        deleteCandidate = nil
        Task {
            do {
                await flush()
                if !isDemoMode { try await store?.remove(item.id); try await store?.publishPending() }
                recordings.removeAll { $0.id == item.id }; dirtyIDs.remove(item.id)
                if selectedID == item.id { selectedID = nil }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
enum DetailTab: String, CaseIterable {
    case transcript = "Transcript", notes = "Notes", summary = "Synthèse" // l10n:ignore (rawValue, use title for display)
    var title: String {
        switch self {
        case .transcript: String(localized: "Transcript")
        case .notes: String(localized: "Notes")
        case .summary: String(localized: "Synthèse")
        }
    }
}
