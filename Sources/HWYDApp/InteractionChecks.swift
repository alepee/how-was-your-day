import Foundation
import AVFoundation
import HWYDCore

@MainActor enum InteractionChecks {
    private static func checkAppearancePreferences(directory: URL) throws {
        let suite = "HWYDAppearanceTests.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suite) else { throw CaptureFailure(message: "Missing isolated preferences") }
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(directory: directory, preferences: preferences, appliesAppearance: false, persistPreferences: true)
        guard model.appearancePreference == .system else { throw CaptureFailure(message: "Appearance must default to system") }
        model.appearancePreference = .dark
        let reopened = AppModel(directory: directory, preferences: preferences, appliesAppearance: false)
        guard reopened.appearancePreference == .dark else { throw CaptureFailure(message: "Appearance did not survive reopening") }
        model.enterDemo(); model.appearancePreference = .light
        let preview = AppModel(preview: true, preferences: preferences, appliesAppearance: false)
        preview.appearancePreference = .system
        reopened.appearancePreference = .light
        guard preferences.string(forKey: "appearancePreference") == "dark" else { throw CaptureFailure(message: "Demo, preview or isolated test changed preferences") }
        model.isDemoMode = false; model.appearancePreference = .system
        guard preferences.string(forKey: "appearancePreference") == "system", model.appearancePreference.appearance == nil, model.appearancePreference.colorScheme == nil else { throw CaptureFailure(message: "System appearance must clear overrides") }
        preferences.set("unknown-future-value", forKey: "appearancePreference")
        let fallback = AppModel(preview: true, preferences: preferences, appliesAppearance: false)
        guard fallback.appearancePreference == .system else { throw CaptureFailure(message: "Invalid preference must follow system") }
        print("Appearance persistence, system fallback and demo/test isolation: PASS")
    }
    private static func checkSummaryLifecycle(directory: URL) async throws {
        let model = AppModel(directory: directory, appliesAppearance: false)
        await model.load()
        let recording = Recording(title: "Summary lifecycle fixture", notes: "Before")
        model.recordings = [recording]; model.selectedID = recording.id
        model.update(recording.id) { $0.notes = "Pending edit" }
        model.summaryEnabled = true
        // An invalid remote endpoint guarantees this test performs no inference or network call.
        model.summaryEndpoint = "https://example.com/v1"; model.summaryModel = "fixture"
        model.generateSummary()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.summaryID != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard model.summaryID == nil, !model.hasUnsavedChanges, model.errorMessage != nil,
              let persisted = try await model.store?.recording(recording.id), persisted.notes == "Pending edit",
              persisted.revision == model.recordings.first?.revision else {
            throw CaptureFailure(message: "Summary did not flush pending edits before provider setup")
        }
        model.errorMessage = nil; model.notice = nil
        model.generateSummary()
        model.enterDemo()
        guard !model.isDemoMode, model.recordings.first?.id == recording.id else {
            model.cancelSummary()
            throw CaptureFailure(message: "Demo replaced recordings during summary generation")
        }
        model.cancelSummary()
        let cancelDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.summaryID != nil, ContinuousClock.now < cancelDeadline { try await Task.sleep(for: .milliseconds(10)) }
        guard model.summaryID == nil, model.errorMessage == nil, model.notice == String(localized: "Synthèse annulée.") else {
            throw CaptureFailure(message: "Cancelled summary surfaced as a provider error")
        }
        print("Summary pending-edit flush, demo exclusion and cancellation: PASS")
    }
    private static func checkAutomaticSummary(directory: URL) async throws {
        let suite = "HWYDAutomaticSummaryTests.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: suite) else { throw CaptureFailure(message: "Missing isolated preferences") }
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = AppModel(directory: directory, preferences: preferences, appliesAppearance: false, persistPreferences: true)
        await model.load()
        model.automaticSummaryDelay = .milliseconds(50)
        // An invalid remote endpoint guarantees this test performs no inference or network call.
        model.summaryEnabled = true; model.summaryAutomatic = true
        model.summaryEndpoint = "https://example.com/v1"; model.summaryModel = "fixture"
        let voice = Speaker(label: "Voix 1")
        let recording = Recording(title: "Automatic summary fixture", speakers: [voice],
                                  segments: [TranscriptSegment(start: 0, end: 1, speakerID: voice.id, source: .mic, text: "Bonjour")])
        model.recordings = [recording]; model.selectedID = recording.id
        func settle() async throws {
            try await Task.sleep(for: .milliseconds(300))
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while model.summaryID != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        }
        model.update(recording.id) { $0.notes = "Unnamed voice" }
        try await settle()
        guard model.errorMessage == nil else { throw CaptureFailure(message: "Automatic summary started before every voice was resolved") }
        model.update(recording.id) { try? $0.renameSpeaker(voice.id, to: "Alice") }
        try await settle()
        guard model.errorMessage != nil else { throw CaptureFailure(message: "Automatic summary did not start once the session was ready") }
        model.errorMessage = nil
        model.update(recording.id) { $0.notes = "Edit after a failed run" }
        try await settle()
        guard model.errorMessage == nil else { throw CaptureFailure(message: "Automatic summary retried an unchanged transcript") }
        model.summaryAutomatic = false
        model.update(recording.id) { try? $0.renameSpeaker(voice.id, to: "Alice B.") }
        try await settle()
        guard model.errorMessage == nil, preferences.bool(forKey: "summary.automatic") == false else {
            throw CaptureFailure(message: "Automatic summary ran while the setting was off")
        }
        print("Automatic summary waits for resolved voices, runs once per transcript and respects the setting: PASS")
    }
    static func runTranscription(directory: URL) async throws {
        let model = AppModel(directory: directory)
        let previousDiarization = model.diarizationEnabled
        model.diarizationEnabled = false
        defer { model.diarizationEnabled = previousDiarization }
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
        if let error = model.errorMessage { throw CaptureFailure(message: error) }
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
        model.errorMessage = nil
        model.transcribe(recording.id)
        while model.pipelineBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard model.recordings.first(where: { $0.id == recording.id })?.transcriptVersion == 2,
              model.errorMessage == nil else { throw CaptureFailure(message: "Retry after cancellation failed") }
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
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/hwyd-mcp")
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

        for toast in model.toasts { model.dismissToast(toast.id) }
        model.notice = "Premier"; model.notice = "Premier"
        model.report("Décision", style: .error, actions: [ToastAction(title: "Réessayer") {}]) // l10n:ignore
        guard model.toasts.count == 2, model.toasts.last?.staysOnScreen == true, model.errorMessage == "Décision" else { throw CaptureFailure(message: "Toasts did not deduplicate or keep their actions") } // l10n:ignore
        for index in 0..<5 { model.notice = "Message \(index)" }
        guard model.toasts.count == 4, model.toasts.contains(where: { $0.message == "Décision" }) else { throw CaptureFailure(message: "Overflow must drop transient toasts before decisions") } // l10n:ignore
        try await Task.sleep(for: .seconds(5.5))
        guard model.toasts.map(\.message) == ["Décision"] else { throw CaptureFailure(message: "Transient toasts must expire, decisions must stay: \(model.toasts.map(\.message))") } // l10n:ignore
        print("New session setup without recording, kind and name, toast stacking, expiry and decisions: PASS")
    }
    static func run(directory: URL) async throws {
        try await PlaybackChecks.run(directory: directory.appendingPathComponent("playback"))
        try checkAppearancePreferences(directory: directory.appendingPathComponent("appearance-test"))
        try await checkSummaryLifecycle(directory: directory.appendingPathComponent("summary-lifecycle-test"))
        try await checkAutomaticSummary(directory: directory.appendingPathComponent("automatic-summary-test"))
        try await checkAgentSummary(directory: directory.appendingPathComponent("agent-summary-test"))
        try await checkNewSessionAndToasts()
        let model = AppModel(directory: directory)
        let previousDiarization = model.diarizationEnabled
        model.diarizationEnabled = false
        defer { model.diarizationEnabled = previousDiarization }
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
        guard let undo = model.toasts.last(where: { $0.actions.first?.title == String(localized: "Annuler") }), !undo.staysOnScreen,
              merged.separableVoices(of: camille.id).map(\.id) == [unknown.id] else { throw CaptureFailure(message: "Merge cannot be undone") }
        model.runToastAction(undo.actions[0], of: undo)
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
        for toast in model.toasts { model.dismissToast(toast.id) }
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
        model.errorMessage = nil
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
