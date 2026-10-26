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
    @Published var showSettings = false
    @Published var settingsCategory: SettingsCategory = .general
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var isDemoMode = false
    @Published var isLoading = true
    @Published var activeCaptureID: UUID?
    @Published var elapsed: Double = 0
    @Published var micLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var isStarting = false
    @Published var isPlaying = false
    @Published var playbackTime: Double = 0
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
    @Published var showVoiceIdentity = false
    private let voiceRunner = PipelineRunner()
    @Published var summaryID: UUID?
    @Published var summaryEnabled = UserDefaults.standard.bool(forKey: "summary.enabled")
    @Published var summaryEndpoint = UserDefaults.standard.string(forKey: "summary.endpoint") ?? "http://127.0.0.1:1234/v1"
    @Published var summaryModel = UserDefaults.standard.string(forKey: "summary.model") ?? ""
    @Published var summaryContextTokens = 32768
    @Published var summaryReasoningDisabled = false
    @Published var summaryProgress: SummaryProgress?
    private var summaryTask: Task<Void, Never>?
    @Published var processingID: UUID?
    @Published var isInstallingDiarizer = false
    @Published var diarizationEnabled = UserDefaults.standard.bool(forKey: "diarizationEnabled") {
        didSet { if persistPreferences && !isDemoMode { preferences.set(diarizationEnabled, forKey: "diarizationEnabled") } }
    }
    @Published var isInstallingModel = false
    private let pipelineRunner = PipelineRunner()
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
    private let player = SessionPlayback()
    private var capture: CaptureController?

    init(directory: URL? = nil, preview: Bool = false, preferences: UserDefaults = .standard, appliesAppearance: Bool = true, persistPreferences: Bool? = nil) {
        calendar = CalendarIntegration(preferences: preferences, allowed: directory == nil && !preview)
        self.preferences = preferences
        self.appliesAppearance = appliesAppearance
        self.persistPreferences = persistPreferences ?? (directory == nil && !preview)
        summaryEnabled = preferences.bool(forKey: "summary.enabled")
        summaryEndpoint = preferences.string(forKey: "summary.endpoint") ?? "http://127.0.0.1:1234/v1"
        summaryModel = preferences.string(forKey: "summary.model") ?? ""
        summaryContextTokens = preferences.integer(forKey: "summary.contextTokens") == 0 ? 32768 : preferences.integer(forKey: "summary.contextTokens")
        summaryReasoningDisabled = preferences.bool(forKey: "summary.reasoningDisabled")
        appearancePreference = AppearancePreference(rawValue: preferences.string(forKey: "appearancePreference") ?? "") ?? .system
        dataDirectory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HWYD")
        if appliesAppearance { NSApp.appearance = appearancePreference.appearance }
        if preview {
            recordings = DemoContent.recordings(); isDemoMode = true; isLoading = false
        } else {
            do { store = try SessionStore(directory: dataDirectory) }
            catch { errorMessage = "Impossible d’ouvrir les données locales : \(error.localizedDescription)"; isLoading = false }
        }
    }
    func load() async {
        guard let store else { return }
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
            if count > 0 { notice = "\(count) session(s) interrompue(s) retrouvée(s). Vos notes sont conservées." }
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
    func select(_ item: Recording) { showSettings = false; stopPlayback(); selectedID = item.id; activeTab = .transcript; playbackTime = 0; mutedTracks = []; soloTracks = []; trackEnvelopes = [:] }
    func library() { showSettings = false; stopPlayback(); selectedID = nil; search = "" }
    func enterDemo() {
        guard activeCaptureID == nil, !pipelineBusy, !hasUnsavedChanges else { return }
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
        if !isDemoMode { dirtyIDs.insert(id); hasUnsavedChanges = true; scheduleSave() }
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
                dirtyIDs.insert(id); errorMessage = "Les dernières modifications ne sont pas enregistrées : \(error.localizedDescription)"
                hasUnsavedChanges = true; return
            }
        }
        hasUnsavedChanges = false
        do { try await store.publishPending() } catch { notice = "Export différé : \(error.localizedDescription)" }
    }
    func retrySave() { errorMessage = nil; scheduleSave() }
    func addTimestamp() {
        guard let id = activeCaptureID else { return }
        update(id) { $0.noteEntries.append(.init(offset: elapsed)) }
    }
    func beginSpeakerEdit(_ speaker: Speaker) { editingSpeakerID = speaker.id; speakerName = speaker.confirmed || speaker.proposedIdentity != nil ? speaker.label : "" }
    func rememberSpeaker(name: String, speakerID: UUID, channel: VoiceChannel) {
        guard let item = selected, !pipelineBusy else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { errorMessage = "Le nom doit contenir entre 1 et 120 caractères."; return }
        var person = people.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame } ?? VoicePerson(name: name)
        guard !person.opposed else { errorMessage = "Cette personne est exclue de la reconnaissance."; return }
        person.enrollmentRequestedAt = Date()
        editingSpeakerID = speakerID; speakerName = name; confirmSpeaker()
        guard selectedID == item.id, editingSpeakerID == nil else { return }
        runVoice(command: "enroll-voice", speakerID: speakerID, person: person, channel: channel)
    }
    func confirmSpeaker() {
        guard let id = selectedID, id != processingID, let speakerID = editingSpeakerID else { return }
        do {
            guard var item = selected else { return }
            let proposal = item.speakers.first { $0.id == speakerID }?.proposedIdentity
            try item.renameSpeaker(speakerID, to: speakerName)
            if let proposal, let person = people.first(where: { $0.id == proposal.personID && $0.recognitionEnabled }),
               person.name == speakerName.trimmingCharacters(in: .whitespacesAndNewlines),
               let index = item.speakers.firstIndex(where: { $0.id == speakerID }) { item.speakers[index].personID = person.id }
            update(id) { $0 = item }; editingSpeakerID = nil
            notice = "Voix corrigée dans toute cette session. Aucune empreinte vocale créée."
        } catch { errorMessage = error.localizedDescription }
    }
    func assignSpeaker(_ speakerID: UUID?, to segmentID: UUID, recordingID: UUID) {
        guard recordingID != processingID,
              var item = recordings.first(where: { $0.id == recordingID }), item.state != .recording else { return }
        do {
            let previousVersion = item.transcriptVersion
            try item.assignSpeaker(speakerID, to: segmentID)
            guard item.transcriptVersion != previousVersion else { return }
            update(recordingID) { $0 = item }
            notice = "Attribution corrigée pour ce passage uniquement."
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
            notice = "Passage découpé. Vous pouvez corriger la voix de chaque partie."
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func joinMeeting(_ event: CalendarContext) {
        showWindow?()
        guard !isDemoMode, activeCaptureID == nil, !isStarting else {
            notice = "Une capture est déjà en cours."; return
        }
        if let existing = recordings.first(where: { $0.calendarContext?.id == event.id }) {
            select(existing); notice = "Cette réunion possède déjà une session."; return
        }
        if let url = event.meetingURL { NSWorkspace.shared.open(url) }
        startCapture(meeting: event)
    }
    func startCapture(meeting: CalendarContext? = nil) {
        guard activeCaptureID == nil, !isStarting else { showWindow?(); return }
        showSettings = false
        startTicker(); stopPlayback(); isStarting = true
        Task {
            defer { isStarting = false }
            let id = UUID()
            if isDemoMode {
                let item = Recording(id: id, title: "Nouvelle conversation", state: .recording, isDemo: true)
                recordings.insert(item, at: 0); activeCaptureID = id; selectedID = id
                elapsed = 0; captureStart = .now; showWindow?(); return
            }
            guard store != nil else { errorMessage = "Le store local n’est pas disponible."; return }
            do {
                let controller = CaptureController()
                try await controller.start(id: id, directory: dataDirectory)
                capture = controller
                var item = Recording(id: id, title: meeting?.title ?? "Session du \(Date().formatted(date: .omitted, time: .shortened))", kind: meeting == nil ? .adHoc : .meeting, state: .recording)
                item.calendarContext = meeting
                recordings.insert(item, at: 0); activeCaptureID = id; selectedID = id
                elapsed = 0; captureStart = .now; dirtyIDs.insert(id)
                await flush(); showWindow?()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func stopCapture() {
        guard let id = activeCaptureID else { return }
        let duration = elapsed
        let chunks = capture?.stop() ?? []
        let finalizationError = capture?.finalizationError
        capture = nil; captureStart = nil; activeCaptureID = nil; micLevel = 0; systemLevel = 0
        update(id) { $0.duration = duration; $0.state = finalizationError == nil ? .sealed : .interrupted; $0.audioChunks = chunks }
        if let finalizationError { errorMessage = finalizationError }
        selectedID = id; activeTab = .notes
        notice = isDemoMode ? "Simulation terminée. Les notes restent disponibles." : (chunks.isEmpty ? "Aucun audio reçu. Vos notes sont conservées." : "Audio et notes conservés. La transcription locale va démarrer.")
        showWindow?()
        if !isDemoMode, !chunks.isEmpty {
            if modelWorkBusy { notice = "Audio conservé. Un traitement est déjà en cours ; lancez la transcription depuis cette session ensuite." }
            else { transcribe(id) }
        }
    }
    func cancelProcessing() { pipelineRunner.cancel(); voiceRunner.cancel() }
    func installSpeechModel() {
        guard !modelWorkBusy, !isDemoMode else { return }
        pipelineRunner.prepare()
        isInstallingModel = true
        Task {
            defer { isInstallingModel = false }
            do {
                let directory = dataDirectory.appendingPathComponent("jobs")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try await pipelineRunner.run(arguments: ["install-model", "fr-FR"], log: directory.appendingPathComponent("install-model.log"))
                notice = "Modèle français installé. La transcription reste locale."
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
                diarizationEnabled = true
                notice = "Séparation des voix activée pour les prochains traitements."
            } catch { errorMessage = "Installation des voix : \(error.localizedDescription)" }
        }
    }
    func transcribe(_ id: UUID) {
        guard !isDemoMode, !modelWorkBusy, let item = recordings.first(where: { $0.id == id }), item.state != .recording, !item.audioChunks.isEmpty else { return }
        pipelineRunner.prepare()
        processingID = id
        let originalVersion = item.transcriptVersion
        update(id) { $0.transcriptState = .pending }
        Task {
            defer { processingID = nil }
            do {
                await flush()
                guard !hasUnsavedChanges else { throw PipelineFailure(message: "Sauvegardez les modifications avant de transcrire.") }
                let job = dataDirectory.appendingPathComponent("jobs/\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let input = job.appendingPathComponent("request.json"), output = job.appendingPathComponent("result.json")
                let request = TranscriptionRequest(recordingID: id, chunks: item.audioChunks, diarize: diarizationEnabled)
                try JSONEncoder().encode(request).write(to: input, options: .atomic)
                try await pipelineRunner.run(arguments: ["transcribe", dataDirectory.path, input.path, output.path], log: job.appendingPathComponent("pipeline.log"))
                let result = try JSONDecoder().decode(TranscriptionResult.self, from: Data(contentsOf: output))
                guard var latest = recordings.first(where: { $0.id == id }), latest.transcriptVersion == originalVersion else { throw TranscriptionError.staleResult }
                try latest.applyTranscription(result)
                update(id) { $0 = latest }
                await flush()
                if !hasUnsavedChanges { try? FileManager.default.removeItem(at: job) }
                notice = result.segments.isEmpty ? "Traitement terminé : aucune parole reconnue." : (result.diarizationEngine == nil ? "Transcript disponible. Les voix ne sont pas séparées." : "Transcript disponible. Les voix détectées peuvent être nommées dans cette session.")
                if let warning = result.identityWarning { notice = "Transcript disponible. " + warning }
            } catch {
                update(id) { $0.transcriptState = .failed }
                errorMessage = "Transcription : \(error.localizedDescription)"
                await flush()
            }
        }
    }
    private func startTicker() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
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
        if isPlaying { playbackTime = player.position; if playbackTime >= (selected?.duration ?? 0) { stopPlayback() } }
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
        if resume { play(at: playbackTime) }
    }
    func play(at time: Double) {
        guard let item = selected, let store, !item.audioChunks.isEmpty else {
            notice = "Aucun fichier audio disponible pour cette session."; return
        }
        stopPlayback()
        do {
            playbackTime = min(max(0, time), item.duration)
            try player.start(chunks: item.audioChunks, store: store, at: playbackTime, duration: item.duration)
            applyTrackMix(); isPlaying = true
        } catch { errorMessage = "Lecture impossible : \(error.localizedDescription)" }
    }
    func stopPlayback() { player.stop(); isPlaying = false }
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
            waveformLoading = false; waveformError = "Formes d’onde indisponibles"
        }
    }
    func runVoice(command: String, speakerID: UUID? = nil, person: VoicePerson? = nil, channel: VoiceChannel = .room) {
        guard !isDemoMode, !modelWorkBusy, let store else { return }
        let item = selected ?? Recording(title: "Gestion des voix")
        voiceBusy = true; voiceRunner.prepare()
        Task {
            defer { voiceBusy = false }
            let folder = dataDirectory.appendingPathComponent("jobs/voice-" + UUID().uuidString)
            do {
                if let person { try await store.savePerson(person); people = try await store.people() }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: folder) }
                let request = folder.appendingPathComponent("request.json"), result = folder.appendingPathComponent("result.json")
                try JSONEncoder().encode(VoiceJob(recording: item, speakerID: speakerID, personID: person?.id, channel: channel)).write(to: request, options: .atomic)
                try await voiceRunner.run(arguments: [command, dataDirectory.path, request.path, result.path], log: folder.appendingPathComponent("log.txt"))
                if command == "identify-voices" {
                    let matches = try JSONDecoder().decode([String: VoiceMatch].self, from: Data(contentsOf: result))
                    guard recordings.first(where: { $0.id == item.id })?.transcriptVersion == item.transcriptVersion else { throw StoreError.conflict }
                    update(item.id) { current in
                        for index in current.speakers.indices {
                            if let match = matches[current.speakers[index].id.uuidString] {
                                current.speakers[index].proposedIdentity = match
                                if !current.speakers[index].confirmed, let person = people.first(where: { $0.id == match.personID }) { current.speakers[index].label = person.name }
                            }
                        }
                    }
                    notice = "\(matches.count) correspondance(s) proposée(s), à confirmer."
                    await flush()
                } else {
                    people = try await store.people()
                    if command == "enroll-voice", let person, let speakerID,
                       recordings.first(where: { $0.id == item.id })?.transcriptVersion == item.transcriptVersion {
                        update(item.id) { current in
                            if let index = current.speakers.firstIndex(where: { $0.id == speakerID }) {
                                current.speakers[index].personID = person.id
                                current.speakers[index].label = person.name
                                current.speakers[index].confirmed = true
                                current.speakers[index].proposedIdentity = nil
                                current.transcriptVersion += 1; current.summary = nil
                            }
                        }
                        await flush()
                    }
                    notice = command == "enroll-voice" ? "Empreinte mémorisée. Cette voix sera recherchée dans les prochaines transcriptions." : "Empreintes supprimées. Opposition enregistrée."
                }
            } catch { errorMessage = "Identité vocale : \(error.localizedDescription)" }
        }
    }
    func confirmIdentity(speakerID: UUID, person: VoicePerson) {
        guard let item = selected, !person.opposed else { return }
        update(item.id) { recording in
            guard let index = recording.speakers.firstIndex(where: { $0.id == speakerID }) else { return }
            recording.speakers[index].personID = person.id
            recording.speakers[index].label = person.name; recording.speakers[index].confirmed = true
            recording.speakers[index].proposedIdentity = nil
            recording.transcriptVersion += 1; recording.summary = nil
        }
    }
    func saveSummarySettings() {
        guard !isDemoMode, persistPreferences else { return }
        preferences.set(summaryEnabled, forKey: "summary.enabled")
        preferences.set(summaryEndpoint, forKey: "summary.endpoint")
        preferences.set(summaryModel, forKey: "summary.model")
        preferences.set(summaryContextTokens, forKey: "summary.contextTokens")
        preferences.set(summaryReasoningDisabled, forKey: "summary.reasoningDisabled")
    }
    func cancelSummary() { summaryTask?.cancel() }
    func generateSummary() {
        guard summaryEnabled, !modelWorkBusy, !isDemoMode, let item = selected, let store else { return }
        summaryID = item.id
        summaryTask = Task {
            defer { summaryID = nil; summaryTask = nil; summaryProgress = nil }
            do {
                guard let url = URL(string: summaryEndpoint) else { throw SummaryFailure.invalidEndpoint }
                let provider = try LocalLLMProvider(endpoint: url, model: summaryModel,
                    reasoningEffort: summaryReasoningDisabled ? "none" : nil)
                let result = try await SummaryPipeline.run(item, provider: provider, model: summaryModel,
                    inputCharacterLimit: max(12_000, (summaryContextTokens - 10_000) * 2),
                    cacheDirectory: dataDirectory.appendingPathComponent("cache/summaries/" + item.id.uuidString), reuseCache: item.summary == nil,
                    providerIdentity: url.absoluteString + "|reasoning=" + (summaryReasoningDisabled ? "none" : "server-default")) { value in
                        await MainActor.run { self.summaryProgress = value }
                    }
                try Task.checkCancellation()
                guard let latest = recordings.first(where: { $0.id == item.id }), latest.transcriptVersion == item.transcriptVersion,
                    try SummaryPipeline.inputHash(latest) == result.inputHash else { throw SummaryFailure.stale }
                let persisted = try await store.recording(item.id)
                guard persisted.revision == item.revision else { throw SummaryFailure.stale }
                update(item.id) { $0.summary = result.structured.markdown; $0.summaryProvenance = result }
                await flush()
            } catch is CancellationError { notice = "Synthèse annulée." }
            catch { errorMessage = "Synthèse : \(error.localizedDescription)" }
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
        panel.prompt = "Utiliser ce dossier"; panel.message = "Les sessions sauvegardées seront publiées ici en Markdown et JSON."
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await store.setSetting("export_directory", value: url.path); exportDirectory = url.path
                    await flush()
                    try await store.publishPending()
                    notice = "Dossier de publication configuré."
                } catch { errorMessage = "Export différé : \(error.localizedDescription)" }
            }
        }
    }
    func exportSelected() {
        guard let item = selected else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Exporter ici"; panel.message = "Choisissez le dossier de sortie pour cette session."
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await flush()
                guard !hasUnsavedChanges else { return }
                do {
                    let current = recordings.first { $0.id == item.id } ?? item
                    try SessionExporter.export(current, to: url); notice = "Session exportée en Markdown et JSON."; NSWorkspace.shared.open(url)
                } catch { errorMessage = "Export impossible : \(error.localizedDescription)" }
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
enum DetailTab: String, CaseIterable { case transcript = "Transcript", notes = "Notes", summary = "Synthèse" }
