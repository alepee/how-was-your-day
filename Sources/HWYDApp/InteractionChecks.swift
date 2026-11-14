import Foundation
import AVFoundation
import HWYDCore

@MainActor enum InteractionChecks {
    private static func checkAppearancePreferences(directory: URL) throws {
        let suite = "HWYDAppearanceTests.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suite) else { throw CaptureFailure(message: "Missing isolated preferences") }
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(directory: directory, settings: UserDefaultsSettings(preferences), appliesAppearance: false, persistPreferences: true)
        guard model.appearancePreference == .system else { throw CaptureFailure(message: "Appearance must default to system") }
        model.appearancePreference = .dark
        let reopened = AppModel(directory: directory, settings: UserDefaultsSettings(preferences), appliesAppearance: false)
        guard reopened.appearancePreference == .dark else { throw CaptureFailure(message: "Appearance did not survive reopening") }
        model.enterDemo(); model.appearancePreference = .light
        let preview = AppModel(preview: true, settings: UserDefaultsSettings(preferences), appliesAppearance: false)
        preview.appearancePreference = .system
        reopened.appearancePreference = .light
        guard preferences.string(forKey: "appearancePreference") == "dark" else { throw CaptureFailure(message: "Demo, preview or isolated test changed preferences") }
        model.isDemoMode = false; model.appearancePreference = .system
        guard preferences.string(forKey: "appearancePreference") == "system", model.appearancePreference.appearance == nil, model.appearancePreference.colorScheme == nil else { throw CaptureFailure(message: "System appearance must clear overrides") }
        preferences.set("unknown-future-value", forKey: "appearancePreference")
        let fallback = AppModel(preview: true, settings: UserDefaultsSettings(preferences), appliesAppearance: false)
        guard fallback.appearancePreference == .system else { throw CaptureFailure(message: "Invalid preference must follow system") }
        print("Appearance persistence, system fallback and demo/test isolation: PASS")
    }
    /// Stands in for a provider: records what it was given, then fails or waits to be cancelled.
    private struct FixtureSummarizer: Summarizer {
        struct Failure: LocalizedError { var errorDescription: String? { "fixture provider" } } // l10n:ignore
        let run: @Sendable (Recording) async throws -> Void
        var availability: SummaryAvailability { .ready }
        var disclosure: SummaryDisclosure { SummaryDisclosure(label: "fixture", detail: "fixture") } // l10n:ignore
        func summarize(_ recording: Recording, progress: @escaping @Sendable (SummaryProgress) async -> Void) async throws -> SummaryProvenance {
            try await run(recording); throw Failure()
        }
    }
    private actor Probe { var given: String?; var stored: String?; func record(_ given: String, _ stored: String?) { self.given = given; self.stored = stored } }
    private static func waitForSummary(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.summaryID != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }
    private static func checkSummaryLifecycle(directory: URL) async throws {
        let model = AppModel(directory: directory, appliesAppearance: false)
        await model.load()
        let recording = Recording(title: "Summary lifecycle fixture", notes: "Before")
        model.recordings = [recording]; model.selectedID = recording.id
        // The summarizer owns its conditions: off, then a non-loopback server, are refused before any run.
        model.summarySettings.enabled = false
        guard model.summaryAvailability == .unavailable(.disabled) else { throw CaptureFailure(message: "Disabled summary must be unavailable") }
        model.summarySettings.enabled = true
        model.summarySettings.select(.local); model.summarySettings.endpoint = "https://example.com/v1"; model.summarySettings.localModel = "fixture"
        guard model.summaryAvailability == .unavailable(.localServerNotConfigured) else {
            throw CaptureFailure(message: "A non-loopback summary server must be unavailable")
        }
        model.generateSummary()
        guard model.summaryID == nil, model.toastCenter.toasts.contains(where: { $0.style == .error && $0.actions.first?.title == String(localized: "Réglages") }) else {
            throw CaptureFailure(message: "Unavailable summary did not explain why")
        }
        model.toastCenter.dismissAll()
        // Pending edits reach the store before the provider runs.
        let probe = Probe()
        let store = model.store
        model.summarizerOverride = FixtureSummarizer { given in
            let stored = try await store?.recording(given.id).notes
            await probe.record(given.notes, stored)
        }
        model.update(recording.id) { $0.notes = "Pending edit" }
        model.generateSummary()
        try await waitForSummary(model)
        let given = await probe.given, stored = await probe.stored
        guard model.summaryID == nil, !model.hasUnsavedChanges, model.toastCenter.toasts.contains(where: { $0.style == .error }), given == "Pending edit", stored == "Pending edit",
              let persisted = try await model.store?.recording(recording.id), persisted.notes == "Pending edit",
              persisted.revision == model.recordings.first?.revision else {
            throw CaptureFailure(message: "Summary did not flush pending edits before the provider ran")
        }
        model.toastCenter.dismissAll()
        model.summarizerOverride = FixtureSummarizer { _ in try await Task.sleep(for: .seconds(30)) }
        model.generateSummary()
        model.enterDemo()
        guard !model.isDemoMode, model.recordings.first?.id == recording.id else {
            model.cancelSummary()
            throw CaptureFailure(message: "Demo replaced recordings during summary generation")
        }
        model.cancelSummary()
        try await waitForSummary(model)
        guard model.summaryID == nil, !model.toastCenter.toasts.contains(where: { $0.style == .error }),
              model.toastCenter.toasts.last?.message == String(localized: "Synthèse annulée.") else {
            throw CaptureFailure(message: "Cancelled summary surfaced as a provider error")
        }
        print("Summary availability, pending-edit flush, demo exclusion and cancellation: PASS")
    }
    /// Synthetic placeholder files stand in for audio and derived files; no microphone.
    private static func checkSessionDeletion(directory: URL) async throws {
        let model = AppModel(directory: directory, appliesAppearance: false)
        await model.load()
        guard let store = model.store else { throw CaptureFailure(message: "Deletion check needs a store") }
        func write(_ relative: String) throws {
            let url = directory.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic".utf8).write(to: url)
        }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path) }
        var deleted = Recording(title: "Deletion fixture", state: .sealed)
        let audio = "audio/" + deleted.id.uuidString.lowercased()
        deleted.audioChunks = [.init(source: .mic, relativePath: audio + "/mic-000000.caf", start: 0, duration: 1),
                               .init(source: .system, relativePath: audio + "/system-000000.caf", start: 0, duration: 1)]
        for chunk in deleted.audioChunks { try write(chunk.relativePath) }
        try write("cache/summaries/\(deleted.id.uuidString)/evidence.json")
        deleted = try await store.save(deleted)
        let kept = try await store.save(Recording(title: "Kept fixture", state: .sealed))
        let earlier = "audio/\(UUID().uuidString.lowercased())"
        try write(earlier + "/mic-000000.caf")
        let quiet = Date.now.addingTimeInterval(-2 * SessionFiles.orphanQuietPeriod)
        for path in [earlier + "/mic-000000.caf", earlier] {
            try FileManager.default.setAttributes([.modificationDate: quiet], ofItemAtPath: directory.appendingPathComponent(path).path)
        }
        // A capture that is starting has a folder but no row yet.
        let starting = "audio/\(UUID().uuidString.lowercased())/mic-000000.partial.caf"
        try write(starting)
        await model.load()
        let sweepDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while exists(earlier), ContinuousClock.now < sweepDeadline { try await Task.sleep(for: .milliseconds(10)) }
        guard !exists(earlier) else { throw CaptureFailure(message: "Launch kept the audio of a session deleted earlier") }
        guard exists(starting) else { throw CaptureFailure(message: "Launch sweep removed the folder of a starting capture") }
        model.deleteCandidate = model.recordings.first { $0.id == deleted.id }
        model.deleteConfirmed()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.recordings.contains(where: { $0.id == deleted.id }), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let remaining = try await store.all()
        guard !exists(audio), !exists("cache/summaries/" + deleted.id.uuidString),
              !model.toastCenter.toasts.contains(where: { $0.style == .error }),
              remaining.map(\.id) == [kept.id], model.recordings.map(\.id) == [kept.id] else {
            throw CaptureFailure(message: "Deleting a session left its files or rows behind")
        }
        print("Session deletion removes audio and derived files, launch sweep of earlier deletions: PASS")
    }
    static func runTranscription(directory: URL) async throws {
        let model = AppModel(directory: directory)
        // Synthetic checks read no user preference: voice separation starts off.
        guard !model.diarizationEnabled else { throw CaptureFailure(message: "A test model read the user's preferences") }
        await model.load()
        var recording = Recording(title: "ASR synthétique", notes: "Avant traitement") // l10n:ignore
        recording.audioChunks = [
            .init(source: .mic, relativePath: "sample.caf", start: 0, duration: 6.2),
            .init(source: .system, relativePath: "sample.caf", start: 300, duration: 6.2)]
        model.recordings.insert(recording, at: 0)
        model.update(recording.id) { $0.notes = "Avant traitement" } // l10n:ignore
        await model.flush()
        model.transcribe(recording.id)
        model.update(recording.id) { $0.notes = "Note écrite pendant la transcription" } // l10n:ignore
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while model.pipelineBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard !model.pipelineBusy else { model.cancelProcessing(); throw CaptureFailure(message: "ASR timeout") }
        if let error = model.toastCenter.toasts.last(where: { $0.style == .error }) { throw CaptureFailure(message: error.message) }
        let saved = try await SessionStore(directory: directory).all()
        guard let item = saved.first(where: { $0.id == recording.id }),
              item.transcriptState == .ready, item.transcriptVersion == 1,
              item.notes == "Note écrite pendant la transcription", // l10n:ignore
              item.segments.contains(where: { $0.source == .mic && $0.text.localizedStandardContains("prototype") }),
              item.segments.contains(where: { $0.source == .system && $0.start >= 300 }),
              item.segments.allSatisfy({ !($0.words ?? []).isEmpty && $0.speakerID == nil }),
              item.transcription?.locale == "fr-FR"
        else { throw CaptureFailure(message: "ASR output or notes preservation failed") }
        model.transcribe(recording.id)
        model.cancelProcessing()
        while model.pipelineBusy { try await Task.sleep(for: .milliseconds(100)) }
        guard let cancelled = model.recordings.first(where: { $0.id == recording.id }),
              cancelled.transcriptState == .failed, cancelled.segments == item.segments,
              cancelled.notes == item.notes else { throw CaptureFailure(message: "Cancellation lost previous transcript") }
        model.toastCenter.dismissAll()
        model.transcribe(recording.id)
        while model.pipelineBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard model.recordings.first(where: { $0.id == recording.id })?.transcriptVersion == 2,
              !model.toastCenter.toasts.contains(where: { $0.style == .error }) else { throw CaptureFailure(message: "Retry after cancellation failed") }
        print("Real Apple ASR through bundled helper: tracks, timestamps, persistence, concurrent notes, cancellation and retry: PASS")
    }
    /// Agent summaries through the bundled `hwyd-mcp`: a scripted ACP agent connects to the real
    /// helper, sees only `submit_summary`, gets a rejection it can read, then an acceptance.
    private static func checkAgentSummary(directory: URL) async throws {
        let model = AppModel(directory: directory, appliesAppearance: false)
        await model.load()
        let camille = Speaker(label: "Camille", confirmed: true)
        var recording = Recording(title: "Agent fixture", speakers: [camille])
        recording.segments = [TranscriptSegment(start: 0, end: 4, speakerID: camille.id, source: .mic, text: "On valide le lancement."), // l10n:ignore
                              TranscriptSegment(start: 4, end: 8, speakerID: camille.id, source: .mic, text: "Je rédigerai l'annonce.")] // l10n:ignore
        model.recordings = [recording]; model.selectedID = recording.id
        model.update(recording.id) { $0.title = "Agent fixture" }
        await model.flush()
        guard let stored = try await model.store?.recording(recording.id) else { throw CaptureFailure(message: "Agent fixture not stored") }
        let script = directory.appendingPathComponent("agent.py")
        try """
        import json, subprocess, sys
        def send(obj): sys.stdout.write(json.dumps(obj) + "\\n"); sys.stdout.flush()
        server = None
        for line in sys.stdin:
            msg = json.loads(line); m = msg.get("method")
            if m == "initialize": send({"jsonrpc": "2.0", "id": msg["id"], "result": {"protocolVersion": 1, "agentInfo": {"name": "scripted", "version": "1"}}})
            elif m == "session/new":
                server = msg["params"]["mcpServers"][0]
                send({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": "s"}})
            elif m == "session/prompt":
                mcp = subprocess.Popen([server["command"], *server["args"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
                number = [0]
                def rpc(method, params):
                    number[0] += 1
                    mcp.stdin.write(json.dumps({"jsonrpc": "2.0", "id": number[0], "method": method, "params": params}) + "\\n"); mcp.stdin.flush()
                    while True:
                        reply = json.loads(mcp.stdout.readline())
                        if reply.get("id") == number[0]: return reply
                rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "scripted", "version": "1"}})
                mcp.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\\n"); mcp.stdin.flush()
                tools = [t["name"] for t in rpc("tools/list", {})["result"]["tools"]]
                assert tools == ["submit_summary"], tools
                bad = {"overview": "Lancement validé.", "decisions": [], "action_items": [], "details": [{"title": "Lancement", "text": "Validé.", "evidence_segment_ids": ["S9"]}]}  # l10n:ignore
                rejected = rpc("tools/call", {"name": "submit_summary", "arguments": {"summary": bad}})["result"]
                assert rejected.get("isError") and "S9" in rejected["content"][0]["text"], rejected
                good = {"overview": "Camille valide le lancement.", "decisions": [{"text": "Le lancement est validé.", "evidence_segment_ids": ["S1"]}],  # l10n:ignore
                        "action_items": [{"text": "Rédiger l'annonce.", "assignee_name": "Camille", "evidence_segment_ids": ["S2"]}],  # l10n:ignore
                        "details": [{"title": "Lancement", "text": "Le lancement est validé ; Camille rédigera l'annonce.", "evidence_segment_ids": ["S1", "S2"]}],  # l10n:ignore
                        "context": [{"title": "Projet", "text": "Prolonge une décision antérieure.", "sources": ["notes/projet.md"]}]}  # l10n:ignore
                accepted = rpc("tools/call", {"name": "submit_summary", "arguments": {"summary": good}})["result"]
                assert not accepted.get("isError"), accepted
                mcp.stdin.close(); mcp.wait(timeout=10)
                send({"jsonrpc": "2.0", "id": msg["id"], "result": {"stopReason": "end_turn"}})
        """.write(to: script, atomically: true, encoding: .utf8)
        let helper = model.helpers.mcp
        let result = try await ACPSummaryAgent.run(stored, command: "python3 " + script.path, workingDirectory: directory,
                                                   mcpExecutable: helper, storeDirectory: directory)
        guard result.structured.action_items.first?.evidence_segment_ids == [stored.segments[1].id],
              result.structured.context?.first?.sources == ["notes/projet.md"], result.model == "scripted 1" else {
            throw CaptureFailure(message: "Agent summary was not handed off through hwyd-mcp")
        }
        print("ACP agent summary through bundled hwyd-mcp: restricted tools, readable rejection, accepted handoff: PASS")
    }
    /// The setup screen never records by itself, and toasts stack, deduplicate and expire.
    private static func checkNewSessionAndToasts() async throws {
        let model = AppModel(preview: true, appliesAppearance: false)
        model.requestNewSession()
        guard model.showNewSession, model.activeCaptureID == nil else { throw CaptureFailure(message: "New session must open its setup screen without recording") }
        model.newSessionKind = .call
        model.startCapture(kind: model.newSessionKind, title: "  ")
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.activeCaptureID == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard let active = model.activeCapture, active.kind == .call, active.title.hasPrefix(SessionKind.call.label), active.title != SessionKind.call.label, !model.showNewSession else {
            throw CaptureFailure(message: "Kind and default name were not applied")
        }
        model.stopCapture()
        model.startCapture(kind: .voiceMemo, title: "Idée produit") // l10n:ignore
        while model.activeCaptureID == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard model.activeCapture?.title == "Idée produit", model.activeCapture?.kind == .voiceMemo else { throw CaptureFailure(message: "Typed name was not applied") } // l10n:ignore
        model.stopCapture()

        let toasts = model.toastCenter
        toasts.dismissAll()
        model.notifier.notify(.info("Premier")); model.notifier.notify(.info("Premier"))
        model.notifier.notify(.error("Décision", actions: [.perform("Réessayer") {}])) // l10n:ignore
        guard toasts.toasts.count == 2, toasts.toasts.last?.staysOnScreen == true, toasts.toasts.last?.message == "Décision" else { throw CaptureFailure(message: "Toasts did not deduplicate or keep their actions") } // l10n:ignore
        for index in 0..<5 { model.notifier.notify(.info("Message \(index)")) }
        guard toasts.toasts.count == 4, toasts.toasts.contains(where: { $0.message == "Décision" }) else { throw CaptureFailure(message: "Overflow must drop transient toasts before decisions") } // l10n:ignore
        try await Task.sleep(for: .seconds(5.5))
        guard toasts.toasts.map(\.message) == ["Décision"] else { throw CaptureFailure(message: "Transient toasts must expire, decisions must stay: \(toasts.toasts.map(\.message))") } // l10n:ignore
        // A navigating action is handed to the model, which opens the destination.
        let target = model.recordings[0]
        model.showSettings = true
        model.notifier.notify(.success("Prête", actions: [.navigate("Afficher", to: .session(target.id, .notes))])) // l10n:ignore
        guard let ready = toasts.toasts.last else { throw CaptureFailure(message: "Missing navigation toast") }
        toasts.run(ready.actions[0], of: ready)
        guard !model.showSettings, model.selectedID == target.id, model.activeTab == .notes, toasts.toasts.map(\.message) == ["Décision"] else { // l10n:ignore
            throw CaptureFailure(message: "Navigation intent did not open the session tab")
        }
        print("New session setup without recording, kind and name, toast stacking, expiry and decisions: PASS")
    }
    static func run(directory: URL) async throws {
        try await PlaybackChecks.run(directory: directory.appendingPathComponent("playback"))
        try checkAppearancePreferences(directory: directory.appendingPathComponent("appearance-test"))
        try await checkSummaryLifecycle(directory: directory.appendingPathComponent("summary-lifecycle-test"))
        try await checkAgentSummary(directory: directory.appendingPathComponent("agent-summary-test"))
        try await checkSessionDeletion(directory: directory.appendingPathComponent("deletion-test"))
        try await checkNewSessionAndToasts()
        let model = AppModel(directory: directory)
        // Synthetic checks read no user preference: voice separation starts off.
        guard !model.diarizationEnabled else { throw CaptureFailure(message: "A test model read the user's preferences") }
        await model.load()
        let session = Recording(title: "Test UI persistant", notes: "Avant édition") // l10n:ignore
        model.recordings.insert(session, at: 0)
        model.update(session.id) { $0.notes = "Note enregistrée depuis le modèle UI" } // l10n:ignore
        await model.flush()
        guard !model.hasUnsavedChanges else { throw CaptureFailure(message: "UI notes not saved") }
        let reopened = try SessionStore(directory: directory)
        let persisted = try await reopened.all()
        guard persisted.first?.notes == "Note enregistrée depuis le modèle UI" else { throw CaptureFailure(message: "UI persistence failed") } // l10n:ignore
        model.enterDemo()
        guard let example = model.recordings.first, let unknown = example.speakers.first(where: { !$0.confirmed }) else { throw CaptureFailure(message: "Missing demo") }
        model.select(example); model.beginSpeakerEdit(unknown); model.speakerName = "Léa"; model.confirmSpeaker() // l10n:ignore
        guard model.selected?.speakers.first(where: { $0.id == unknown.id })?.label == "Léa", model.selected?.summary == nil else { throw CaptureFailure(message: "UI rename failed") } // l10n:ignore
        guard let beforeCorrection = model.selected,
              let passage = beforeCorrection.segments.first(where: { $0.speakerID != nil }) else {
            throw CaptureFailure(message: "Missing correction fixture")
        }
        model.assignSpeaker(nil, to: passage.id, recordingID: beforeCorrection.id)
        guard let corrected = model.selected,
              corrected.segments.first(where: { $0.id == passage.id })?.speakerID == nil,
              corrected.transcriptVersion == beforeCorrection.transcriptVersion + 1,
              corrected.speakers == beforeCorrection.speakers else {
            throw CaptureFailure(message: "Segment correction changed cluster profiles")
        }
        model.processingID = beforeCorrection.id
        model.assignSpeaker(passage.speakerID, to: passage.id, recordingID: beforeCorrection.id)
        guard model.selected == corrected else { throw CaptureFailure(message: "Correction allowed during processing") }
        model.processingID = nil
        model.assignSpeaker(passage.speakerID, to: passage.id, recordingID: beforeCorrection.id)
        guard model.selected?.segments == beforeCorrection.segments else { throw CaptureFailure(message: "Segment restoration failed") }
        // Regrouping two voices from the tiles is a transcript correction, never an enrollment.
        let peopleBefore = model.people
        guard let camille = model.selected?.speakers.first(where: { $0.label == "Camille" }), let beforeMerge = model.selected else { throw CaptureFailure(message: "Missing merge fixture") }
        model.mergeSpeaker(unknown.id, into: camille.id)
        guard let merged = model.selected, !merged.speakers.contains(where: { $0.id == unknown.id }),
              !merged.segments.contains(where: { $0.speakerID == unknown.id }), model.people == peopleBefore, !model.voiceBusy else {
            throw CaptureFailure(message: "Tile merge failed or triggered enrollment")
        }
        // The merge offers « Annuler » in a toast that still leaves on its own, and can be separated later.
        guard let undo = model.toastCenter.toasts.last(where: { $0.actions.first?.title == String(localized: "Annuler") }), !undo.staysOnScreen,
              merged.separableVoices(of: camille.id).map(\.id) == [unknown.id] else { throw CaptureFailure(message: "Merge cannot be undone") }
        model.toastCenter.run(undo.actions[0], of: undo)
        guard let restored = model.selected, restored.segments == beforeMerge.segments, restored.speakers == beforeMerge.speakers,
              restored.transcriptVersion == merged.transcriptVersion + 1 else { throw CaptureFailure(message: "Merge undo failed") }
        model.mergeSpeaker(unknown.id, into: camille.id)
        model.separateSpeaker(unknown.id, from: camille.id)
        guard let separated = model.selected, separated.segments == beforeMerge.segments,
              Set(separated.speakers.map(\.id)) == Set(beforeMerge.speakers.map(\.id)), separated.absorbedSpeakers == nil else {
            throw CaptureFailure(message: "Separating a merged voice failed")
        }
        model.mergeSpeaker(unknown.id, into: camille.id)
        // Memorizing a named voice waits for an explicit confirmation.
        model.requestEnrollment(camille.id)
        guard model.enrollmentCandidateID == camille.id, !model.voiceBusy, model.people == peopleBefore else { throw CaptureFailure(message: "Enrollment started without confirmation") }
        model.enrollmentCandidateID = nil
        model.toastCenter.dismissAll()
        var splitExample = TranscriptSegment(start: 0, end: 2, speakerID: nil, source: .mic, text: "Oui. Bonjour")
        splitExample.words = [.init(text: "Oui.", start: 0, end: 1), .init(text: " Bonjour", start: 1, end: 2)]
        let splitRecording = Recording(title: "Découpage synthétique", segments: [splitExample], isDemo: true) // l10n:ignore
        model.recordings.append(splitRecording)
        guard model.splitSegment(splitExample, beforeWord: 1, recordingID: splitRecording.id),
              model.recordings.first(where: { $0.id == splitRecording.id })?.segments.count == 2 else {
            throw CaptureFailure(message: "UI split failed")
        }
        guard !model.splitSegment(splitExample, beforeWord: 1, recordingID: splitRecording.id) else {
            throw CaptureFailure(message: "Stale split accepted")
        }
        model.toastCenter.dismissAll()
        model.startCapture()
        try await Task.sleep(for: .milliseconds(650))
        guard let active = model.activeCapture, model.elapsed > 0 else { throw CaptureFailure(message: "Demo capture timer failed") }
        model.toggleCapturePause()
        let frozen = model.elapsed
        try await Task.sleep(for: .milliseconds(450))
        guard model.isCapturePaused, model.elapsed == frozen else { throw CaptureFailure(message: "Paused capture clock moved") }
        model.toggleCapturePause()
        try await Task.sleep(for: .milliseconds(450))
        guard !model.isCapturePaused, model.elapsed > frozen, model.elapsed < frozen + 1 else { throw CaptureFailure(message: "Resumed capture clock wrong: \(model.elapsed) after \(frozen)") }
        model.update(active.id) { $0.notes = "Note pendant la session" } // l10n:ignore
        model.addTimestamp()
        model.stopCapture()
        guard model.selected?.notes == "Note pendant la session", model.selected?.noteEntries.count == 1, model.activeTab == .notes else { throw CaptureFailure(message: "Capture handoff failed") } // l10n:ignore
        let afterDemo = try await reopened.all()
        guard afterDemo.count == 1 else { throw CaptureFailure(message: "Demo leaked into store") }
        FileHandle.standardOutput.write(Data("UI persistence, speaker correction, merge undo and separation, capture timer, notes handoff and demo isolation: PASS\n".utf8))
    }
}
