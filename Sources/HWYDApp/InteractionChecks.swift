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
    static func runTranscription(directory: URL) async throws {
        let model = AppModel(directory: directory)
        let previousDiarization = model.diarizationEnabled
        model.diarizationEnabled = false
        defer { model.diarizationEnabled = previousDiarization }
        await model.load()
        var recording = Recording(title: "ASR synthétique", notes: "Avant traitement")
        recording.audioChunks = [
            .init(source: .mic, relativePath: "sample.caf", start: 0, duration: 6.2),
            .init(source: .system, relativePath: "sample.caf", start: 300, duration: 6.2)]
        model.recordings.insert(recording, at: 0)
        model.update(recording.id) { $0.notes = "Avant traitement" }
        await model.flush()
        model.transcribe(recording.id)
        model.update(recording.id) { $0.notes = "Note écrite pendant la transcription" }
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while model.pipelineBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard !model.pipelineBusy else { model.cancelProcessing(); throw CaptureFailure(message: "ASR timeout") }
        if let error = model.errorMessage { throw CaptureFailure(message: error) }
        let saved = try await SessionStore(directory: directory).all()
        guard let item = saved.first(where: { $0.id == recording.id }),
              item.transcriptState == .ready, item.transcriptVersion == 1,
              item.notes == "Note écrite pendant la transcription",
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
    static func run(directory: URL) async throws {
        try await PlaybackChecks.run(directory: directory.appendingPathComponent("playback"))
        try checkAppearancePreferences(directory: directory.appendingPathComponent("appearance-test"))
        let model = AppModel(directory: directory)
        let previousDiarization = model.diarizationEnabled
        model.diarizationEnabled = false
        defer { model.diarizationEnabled = previousDiarization }
        await model.load()
        let session = Recording(title: "Test UI persistant", notes: "Avant édition")
        model.recordings.insert(session, at: 0)
        model.update(session.id) { $0.notes = "Note enregistrée depuis le modèle UI" }
        await model.flush()
        guard !model.hasUnsavedChanges else { throw CaptureFailure(message: "UI notes not saved") }
        let reopened = try SessionStore(directory: directory)
        let persisted = try await reopened.all()
        guard persisted.first?.notes == "Note enregistrée depuis le modèle UI" else { throw CaptureFailure(message: "UI persistence failed") }
        model.enterDemo()
        guard let example = model.recordings.first, let unknown = example.speakers.first(where: { !$0.confirmed }) else { throw CaptureFailure(message: "Missing demo") }
        model.select(example); model.beginSpeakerEdit(unknown); model.speakerName = "Léa"; model.confirmSpeaker()
        guard model.selected?.speakers.first(where: { $0.id == unknown.id })?.label == "Léa", model.selected?.summary == nil else { throw CaptureFailure(message: "UI rename failed") }
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
        var splitExample = TranscriptSegment(start: 0, end: 2, speakerID: nil, source: .mic, text: "Oui. Bonjour")
        splitExample.words = [.init(text: "Oui.", start: 0, end: 1), .init(text: " Bonjour", start: 1, end: 2)]
        let splitRecording = Recording(title: "Découpage synthétique", segments: [splitExample], isDemo: true)
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
        model.update(active.id) { $0.notes = "Note pendant la session" }
        model.addTimestamp()
        model.stopCapture()
        guard model.selected?.notes == "Note pendant la session", model.selected?.noteEntries.count == 1, model.activeTab == .notes else { throw CaptureFailure(message: "Capture handoff failed") }
        let afterDemo = try await reopened.all()
        guard afterDemo.count == 1 else { throw CaptureFailure(message: "Demo leaked into store") }
        FileHandle.standardOutput.write(Data("UI persistence, speaker correction, capture timer, notes handoff and demo isolation: PASS\n".utf8))
    }
}
