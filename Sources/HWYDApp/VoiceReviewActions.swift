import Foundation
import Observation
import HWYDCore

/// Fast-changing playback values. Observation tracks them per property, so a 5 Hz clock
/// only invalidates the views that read `time`, not every `AppModel` observer.
@Observable @MainActor final class PlaybackState {
    var time: Double = 0
    var isPlaying = false
    /// Speaker whose passages play back to back, if any.
    var voiceID: UUID?
    /// Segments heard at `time`. Updated only when the set changes.
    var activeSegmentIDs: Set<UUID> = []
    /// Incremented on each user-started playback, so the transcript resumes following.
    var generation = 0
}

extension AppModel {
    var voiceEditingLocked: Bool {
        guard let item = selected else { return true }
        return item.id == processingID || item.state == .recording
    }
    func updatePlaybackFocus() {
        let ids = selected?.segmentIDs(at: playbackTime) ?? []
        if ids != playback.activeSegmentIDs { playback.activeSegmentIDs = ids }
    }
    /// Plays only this voice's passages, on its own track. A second click stops.
    func toggleVoicePlayback(_ speakerID: UUID) {
        if playback.voiceID == speakerID { stopPlayback(); return }
        guard let item = selected, let store, !item.audioChunks.isEmpty else {
            notifier.notify(.info(String(localized: "Aucun fichier audio disponible pour cette session."))); return
        }
        guard let voice = item.voiceOverview.first(where: { $0.id == speakerID }), !voice.spans.isEmpty else {
            notifier.notify(.info(String(localized: "Aucun passage attribué à cette voix."))); return
        }
        stopPlayback()
        do {
            try player.start(playlist: VoicePlaylist(spans: voice.spans), source: voice.speaker.source, chunks: item.audioChunks, store: store)
            playbackTime = player.position; isPlaying = true
            playback.voiceID = speakerID; playback.generation += 1
            updatePlaybackFocus()
        } catch { notifier.notify(.error(String(localized: "Lecture impossible : \(error.localizedDescription)"))) }
    }
    /// Applies a correction to the voices of the selected session and offers to undo it.
    /// Corrections never read or write a voice print.
    @discardableResult
    func editVoices(_ message: (Recording) -> String, _ edit: (inout Recording) throws -> Void) -> Bool {
        guard let id = selectedID, !voiceEditingLocked, var item = selected else { return false }
        let before = item
        do {
            try edit(&item)
            guard item.transcriptVersion != before.transcriptVersion else { return true }
            update(id) { $0 = item }
            if let voice = playback.voiceID, !item.speakers.contains(where: { $0.id == voice && !$0.ignored }) { stopPlayback() }
            let after = item.transcriptVersion
            notifier.notify(.success(message(item), actions: [.perform(String(localized: "Annuler")) { [weak self] in self?.undoVoiceEdit(id, restoring: before, ifStillAt: after) }], optional: true))
            return true
        } catch { notifier.notify(.error(error.localizedDescription)); return false }
    }
    /// Puts the voices back as they were, unless the transcript changed again since.
    func undoVoiceEdit(_ id: UUID, restoring before: Recording, ifStillAt version: Int) {
        guard let current = recordings.first(where: { $0.id == id }), current.transcriptVersion == version,
              id != processingID, current.state != .recording else {
            notifier.notify(.error(String(localized: "Annulation impossible : la session a changé depuis."))); return
        }
        update(id) { item in
            item.speakers = before.speakers; item.absorbedSpeakers = before.absorbedSpeakers
            item.segments = before.segments; item.summary = before.summary
            item.transcriptVersion = version + 1
        }
        if let voice = playback.voiceID, !before.speakers.contains(where: { $0.id == voice }) { stopPlayback() }
        notifier.notify(.info(String(localized: "Modification annulée.")))
    }
    private func label(_ id: UUID, in item: Recording) -> String { item.speakers.first { $0.id == id }?.label ?? String(localized: "Voix") }
    /// "This voice is the same person as that one." Transcript correction only, no enrollment.
    func mergeSpeaker(_ sourceID: UUID, into targetID: UUID) {
        let source = selected.map { label(sourceID, in: $0) } ?? String(localized: "Voix")
        editVoices({ String(localized: "\(source) regroupée avec \(self.label(targetID, in: $0)).") }) { try $0.mergeSpeaker(sourceID, into: targetID) }
    }
    /// Undoes a former merge: the passages first detected as `absorbedID` return to their own voice.
    func separateSpeaker(_ absorbedID: UUID, from speakerID: UUID) {
        editVoices({ String(localized: "\(self.label(absorbedID, in: $0)) séparée de \(self.label(speakerID, in: $0)).") }) { try $0.separateSpeaker(absorbedID, from: speakerID) }
    }
    /// Hides an echo or noise voice from this session, or restores it. Segments are kept.
    func setSpeakerIgnored(_ speakerID: UUID, _ ignored: Bool) {
        editVoices({ ignored ? String(localized: "\(self.label(speakerID, in: $0)) ignorée : ses passages sont masqués du transcript, de l’export et de la synthèse.") : String(localized: "\(self.label(speakerID, in: $0)) rétablie dans le transcript.") }) {
            try $0.setSpeakerIgnored(speakerID, ignored)
        }
    }
    /// Names a voice after a known person. Does not enroll and does not read any voice print.
    func linkSpeaker(_ speakerID: UUID, to person: VoicePerson) {
        editVoices({ _ in String(localized: "Voix nommée \(person.name) dans toute cette session.") }) { try $0.linkSpeaker(speakerID, to: person) }
    }
}
