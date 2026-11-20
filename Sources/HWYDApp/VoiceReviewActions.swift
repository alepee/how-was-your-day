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
        guard let item = selected, let audio, !item.audioChunks.isEmpty else {
            notifier.notify(.info(String(localized: "Aucun fichier audio disponible pour cette session."))); return
        }
        guard let voice = item.voiceOverview.first(where: { $0.id == speakerID }), !voice.spans.isEmpty else {
            notifier.notify(.info(String(localized: "Aucun passage attribué à cette voix."))); return
        }
        playVoice(speakerID, spans: voice.spans, source: voice.speaker.source, in: item, audio: audio)
    }
    /// Plays only the passages a split proposal would move out of its voice. A second click stops.
    func toggleSplitPartPlayback(_ proposalID: UUID) {
        if playback.voiceID == proposalID { stopPlayback(); return }
        guard let item = selected, let audio, !item.audioChunks.isEmpty, let part = item.splitParts(proposalID)?.smaller, let source = part.first?.source else {
            notifier.notify(.info(String(localized: "Aucun fichier audio disponible pour cette session."))); return
        }
        playVoice(proposalID, spans: part.map { VoiceSpan(start: $0.start, end: $0.end) }, source: source, in: item, audio: audio)
    }
    /// `id` names what plays: a voice, or a split proposal for the part it would move.
    private func playVoice(_ id: UUID, spans: [VoiceSpan], source: AudioSource, in item: Recording, audio: any AudioLocator) {
        stopPlayback()
        do {
            try player.start(playlist: VoicePlaylist(spans: spans), source: source, chunks: item.audioChunks, audio: audio)
            playbackTime = player.position; isPlaying = true
            playback.voiceID = id; playback.generation += 1
            updatePlaybackFocus(); startPlaybackClock()
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
            item.splitProposals = before.splitProposals
            item.segments = before.segments
            item.transcriptVersion = version + 1
            // The transcript is back to what it was: a summary that was current then is current again.
            if item.summary == before.summary, before.summary != nil, !before.summaryIsStale {
                item.summaryProvenance?.transcriptVersion = item.transcriptVersion
            }
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
    /// "This voice was two people in turn." The part that does not keep the name becomes a new voice,
    /// whose name editor opens. Transcript correction only, no enrollment.
    func splitSpeaker(at segmentID: UUID, keepingIdentity side: VoiceSplitSide) {
        var created: UUID?
        let applied = editVoices({ String(localized: "Voix scindée : \(self.label(created ?? UUID(), in: $0)) créée.") }) {
            created = try $0.splitSpeaker(at: segmentID, keepingIdentity: side)
        }
        nameNewVoice(created, applied: applied)
    }
    /// Gives one passage a voice of its own, then opens its name editor.
    func assignNewSpeaker(to segmentID: UUID) {
        var created: UUID?
        let applied = editVoices({ String(localized: "Passage attribué à \(self.label(created ?? UUID(), in: $0)).") }) {
            created = try $0.assignNewSpeaker(to: segmentID)
        }
        nameNewVoice(created, applied: applied)
    }
    private func nameNewVoice(_ id: UUID?, applied: Bool) {
        guard applied, let id, let voice = selected?.speakers.first(where: { $0.id == id }) else { return }
        beginSpeakerEdit(voice)
    }
    /// Hides an echo or noise voice from this session, or restores it. Segments are kept.
    func setSpeakerIgnored(_ speakerID: UUID, _ ignored: Bool) {
        editVoices({ ignored ? String(localized: "\(self.label(speakerID, in: $0)) ignorée : ses passages sont masqués du transcript, de l’export et de la synthèse.") : String(localized: "\(self.label(speakerID, in: $0)) rétablie dans le transcript.") }) {
            try $0.setSpeakerIgnored(speakerID, ignored)
        }
    }
    /// "Yes, this voice held two people." The part the proposal names becomes a voice, or joins the
    /// one it sounds like. Transcript correction only, no enrollment.
    func acceptSplit(_ proposalID: UUID) {
        var holder: UUID?
        editVoices({ String(localized: "Voix séparée : passages attribués à \(self.label(holder ?? UUID(), in: $0)).") }) {
            holder = try $0.acceptSplit(proposalID, people: self.people)
        }
    }
    /// "No, this voice is one person." The proposal goes away; nothing else changes.
    func dismissSplit(_ proposalID: UUID) {
        editVoices({ _ in String(localized: "Proposition retirée : la voix reste telle quelle.") }) { try $0.dismissSplit(proposalID) }
    }
    /// Puts a voice set aside as too brief back among the voices to name.
    func restoreMinorVoice(_ speakerID: UUID) {
        editVoices({ String(localized: "\(self.label(speakerID, in: $0)) compte de nouveau parmi les voix à nommer.") }) { try $0.restoreMinorVoice(speakerID) }
    }
    /// Names a voice after a known person. Does not enroll and does not read any voice print.
    func linkSpeaker(_ speakerID: UUID, to person: VoicePerson) {
        editVoices({ _ in String(localized: "Voix nommée \(person.name) dans toute cette session.") }) { try $0.linkSpeaker(speakerID, to: person) }
    }
}
