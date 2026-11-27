import SwiftUI
import HWYDCore

/// One tile per detected voice: listen to its passages, then name or regroup it once for the whole session.
struct VoiceTilesView: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    var body: some View {
        // Voices to name first, then the ones too brief to name, then the ignored ones: those are
        // done, like confirmed ones, but rarely revisited.
        let overview = recording.voiceOverview
        let voices = overview.filter { $0.state != .ignored && $0.state != .minor } + overview.filter { $0.state == .minor } + overview.filter { $0.state == .ignored }
        let proposals = recording.pendingSplitProposals
        let pending = voices.filter { $0.state == .unidentified || $0.state == .proposed }.count
        let playingID = model.playback.voiceID
        let locked = model.voiceEditingLocked
        let known = model.people.filter { !$0.opposed }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Eyebrow(text: voices.isEmpty ? String(localized: "Voix") : pending == 0 ? String(localized: "Voix · \(voices.count)") : String(localized: "Voix · \(pending) à nommer"))
                if !voices.isEmpty {
                    HelpButton(text: String(localized: "Cliquez une voix pour écouter ses passages. Glissez-la sur une autre pour regrouper une même personne. Mémorisez une voix pour la reconnaître dans les prochaines sessions. Après la transcription, HWYD regroupe les voix d’une même personne, masque l’écho de l’appel capté par le micro et met de côté les voix trop brèves : chaque décision se défait depuis le menu de la voix."))
                }
                if model.work.running?.kind == .voice, model.work.running?.sessionID == recording.id {
                    ProgressView().controlSize(.small).padding(.leading, 4)
                    Text("Traitement local…").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
                } else if !model.queuedVoiceWork(of: recording.id).isEmpty {
                    Image(systemName: "clock").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).padding(.leading, 4)
                    Text("En attente…").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
                        .help("Démarre à la fin du traitement en cours.")
                    Button("Annuler") { model.cancelQueuedVoiceWork(of: recording.id) }.buttonStyle(StudioButtonStyle(compact: true))
                }
                Spacer(minLength: 8)
                if !voices.isEmpty, model.people.contains(where: { $0.recognitionEnabled && !$0.channels.isEmpty }) {
                    Button("Reconnaître les voix") { model.identifyVoices() }.buttonStyle(StudioButtonStyle(compact: true))
                        .disabled(recording.isDemo || locked || model.work.isQueued(.voice(session: recording.id)))
                        .help("Compare les voix non confirmées de cette session aux personnes mémorisées. Chaque proposition reste à confirmer.")
                }
            }
            if !voices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(voices) { voice in
                            VoiceTile(voice: voice, playing: playingID == voice.id, canPlay: !recording.audioChunks.isEmpty && !voice.spans.isEmpty,
                                      locked: locked, others: recording.speakers.filter { $0.id != voice.id && !$0.ignored }, people: model.people,
                                      proposed: voice.speaker.proposedIdentity.flatMap { match in known.first { $0.id == match.personID } },
                                      separable: recording.separableVoices(of: voice.id),
                                      canRemember: !recording.isDemo,
                                      opposed: model.people.contains { $0.opposed && ($0.id == voice.speaker.personID || $0.name == voice.speaker.label) })
                        }
                    }.padding(.vertical, 1)
                }
            }
            ForEach(proposals) { proposal in
                SplitProposalRow(proposal: proposal, recording: recording, locked: locked, playing: playingID == proposal.id,
                                 target: proposal.mergeInto.flatMap { id in recording.speakers.first { $0.id == id && !$0.ignored } },
                                 person: proposal.proposedIdentity.flatMap { match in known.first { $0.id == match.personID } })
            }
        }
        .confirmationDialog(enrollmentTitle, isPresented: Binding(get: { model.enrollmentCandidateID != nil }, set: { if !$0 { model.enrollmentCandidateID = nil } }), titleVisibility: .visible) {
            Button("Mémoriser") { model.confirmEnrollment() }
            Button("Annuler", role: .cancel) { model.enrollmentCandidateID = nil }
        } message: {
            Text("Une empreinte de cette voix est ajoutée au trousseau de ce Mac pour la reconnaître dans les prochaines sessions. Faites-le seulement avec l’accord de la personne. Vous pourrez retirer cet apport dans Réglages › Audio et voix.")
        }
    }
    private var enrollmentTitle: String {
        guard let name = recording.speakers.first(where: { $0.id == model.enrollmentCandidateID })?.label else { return String(localized: "Mémoriser cette voix ?") }
        return String(localized: "Mémoriser la voix de \(name) ?")
    }
}

private struct VoiceTile: View {
    @EnvironmentObject var model: AppModel
    let voice: VoiceOverview
    let playing: Bool
    let canPlay: Bool
    let locked: Bool
    let others: [Speaker]
    let people: [VoicePerson]
    let proposed: VoicePerson?
    let separable: [Speaker]
    let canRemember: Bool
    let opposed: Bool
    @State private var targeted = false
    /// The model needs about 20 seconds of clean speech; overlaps are left out.
    private var enoughSpeech: Bool { voice.speechDuration >= 20 }
    private var accent: Color { voice.state == .confirmed ? Studio.mint : voice.state == .ignored || voice.state == .minor ? Studio.muted : Studio.copper }
    /// What sets this voice aside, after its track and speech time.
    private var aside: String? {
        switch voice.state {
        case .ignored: voice.speaker.automatic == .echo ? String(localized: "écho probable") : String(localized: "ignorée")
        case .minor: String(localized: "trop brève")
        default: separable.contains { $0.automatic == .merged } ? String(localized: "regroupée") : nil
        }
    }
    var body: some View {
        HStack(spacing: 0) {
            Button { model.toggleVoicePlayback(voice.id) } label: {
                HStack(spacing: 9) {
                    Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: 9))
                        .foregroundStyle(playing ? Studio.onAccent : accent)
                        .frame(width: 24, height: 24).background(playing ? Studio.mint : accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(voice.speaker.label).font(.system(size: Studio.Size.body, weight: .medium)).lineLimit(1)
                        Text(verbatim: "\(sourceLabel(voice.speaker.source)) · \(speechLabel(voice.speechDuration))" + (aside.map { " · " + $0 } ?? "")).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).lineLimit(1)
                    }
                }.padding(.leading, 10).padding(.trailing, 6).frame(maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canPlay)
                .help(canPlay ? (playing ? "Arrêter l’écoute" : "Écouter uniquement les passages de cette voix") : "Aucun audio pour cette voix")
                .accessibilityLabel(playing ? "Arrêter l’écoute de \(voice.speaker.label)" : "Écouter \(voice.speaker.label)")
            Rectangle().fill(Studio.line).frame(width: 0.5).padding(.vertical, 8)
            Menu { menuContent } label: {
                Text(actionTitle).font(.system(size: Studio.Size.caption, weight: .medium)).foregroundStyle(accent)
            } primaryAction: { primaryAction() }
                .menuStyle(.borderlessButton).menuIndicator(.visible).controlSize(.small).font(.system(size: Studio.Size.caption, weight: .medium)).tint(accent).fixedSize()
                .padding(.horizontal, 10).frame(maxHeight: .infinity).contentShape(Rectangle())
                .disabled(locked)
                .help(stateHelp)
        }
        .frame(height: 44)
        .opacity(voice.state == .ignored && !playing ? 0.6 : 1)
        .background(playing ? Studio.mint.opacity(0.1) : Studio.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(targeted ? Studio.mint : accent.opacity(voice.state == .confirmed ? 0.35 : 0.7),
                                                                style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: voice.state == .unidentified && !targeted ? [4, 3] : [])))
        .overlay(alignment: .topTrailing) { stateDot.padding(6) }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .draggable(voice.id.uuidString) {
            Label(voice.speaker.label, systemImage: "person.wave.2").font(.system(size: Studio.Size.body, weight: .medium)).padding(8)
                .background(Studio.surface, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { items, _ in
            guard !locked, voice.state != .ignored, let first = items.first, let source = UUID(uuidString: first), source != voice.id,
                  others.contains(where: { $0.id == source }) else { return false }
            model.mergeSpeaker(source, into: voice.id)
            return true
        } isTargeted: { targeted = $0 && !locked && voice.state != .ignored }
    }
    private var stateDot: some View {
        Circle().fill(accent).frame(width: 6, height: 6)
            .opacity(voice.state == .unidentified ? 0.6 : 1)
            .accessibilityLabel(stateHelp)
    }
    private var actionTitle: String {
        switch voice.state {
        case .unidentified: String(localized: "Nommer")
        case .proposed: proposed == nil ? String(localized: "Nommer") : String(localized: "Confirmer")
        case .confirmed: String(localized: "Modifier")
        case .ignored, .minor: String(localized: "Rétablir")
        }
    }
    private var stateHelp: String {
        switch voice.state {
        case .unidentified: String(localized: "Voix non identifiée")
        case .proposed: voice.speaker.proposedIdentity.map { String(localized: "Proposition à confirmer (score \($0.score.formatted(.number.precision(.fractionLength(2)))))") } ?? String(localized: "Proposition à confirmer")
        case .confirmed: String(localized: "Voix confirmée")
        case .ignored: voice.speaker.automatic == .echo
            ? String(localized: "Écho probable : cette voix du micro ne s’entend que pendant que l’appel parle. Passages masqués du transcript, de l’export et de la synthèse")
            : String(localized: "Voix ignorée : passages masqués du transcript, de l’export et de la synthèse")
        case .minor: String(localized: "Voix trop brève pour être nommée : ses passages restent dans le transcript sous « Autre voix »")
        }
    }
    private func primaryAction() {
        if voice.state == .ignored { model.setSpeakerIgnored(voice.id, false); return }
        if voice.state == .minor { model.restoreMinorVoice(voice.id); return }
        if voice.state == .proposed, let proposed { model.linkSpeaker(voice.id, to: proposed) }
        else { model.beginSpeakerEdit(voice.speaker) }
    }
    @ViewBuilder private var menuContent: some View {
        if voice.state == .ignored {
            Button("Rétablir cette voix") { model.setSpeakerIgnored(voice.id, false) }
        } else {
            if voice.state == .minor {
                Button("Compter parmi les voix à nommer") { model.restoreMinorVoice(voice.id) }
                Divider()
            }
            namingMenu
            Divider()
            rememberButton
            if !separable.isEmpty {
                Section("Regroupements") {
                    ForEach(separable) { other in
                        Button(other.automatic == .merged ? "Séparer \(other.label) (regroupée automatiquement)" : "Séparer \(other.label)") { model.separateSpeaker(other.id, from: voice.id) }
                    }
                }
            }
            Divider()
            Button("Ignorer cette voix (écho, bruit)") { model.setSpeakerIgnored(voice.id, true) }
        }
    }
    /// Enrollment is always a distinct, explicit request: naming or regrouping never stores a voice print.
    @ViewBuilder private var rememberButton: some View {
        if opposed {
            Button("Mémoriser : exclue de la reconnaissance") {}.disabled(true)
        } else if !enoughSpeech {
            Button("Mémoriser : 20 s de parole minimum") {}.disabled(true)
        } else if voice.state == .confirmed {
            Button("Mémoriser cette voix…") { model.requestEnrollment(voice.id) }.disabled(!canRemember)
        } else {
            Button("Nommer et mémoriser…") { model.beginSpeakerEdit(voice.speaker) }.disabled(!canRemember)
        }
    }
    @ViewBuilder private var namingMenu: some View {
        if voice.state == .proposed, let proposed {
            Button("Confirmer : \(proposed.name)") { model.linkSpeaker(voice.id, to: proposed) }
        }
        Button("Saisir un nom…") { model.beginSpeakerEdit(voice.speaker) }
        if !others.isEmpty {
            Section("Même personne que") {
                ForEach(others) { other in
                    // Two unnamed voices on different tracks cannot share a name yet.
                    Button("\(other.label) · \(sourceLabel(other.source))") { model.mergeSpeaker(voice.id, into: other.id) }
                        .disabled(other.source != voice.speaker.source && !other.confirmed && !voice.speaker.confirmed)
                }
            }
        }
        if !people.isEmpty {
            Section("Personnes connues") {
                ForEach(people) { person in Button(person.name) { model.linkSpeaker(voice.id, to: person) } }
            }
        }
    }
}

/// A voice the post-processing found to hold two people: listen to the part it would move, then answer.
private struct SplitProposalRow: View {
    @EnvironmentObject var model: AppModel
    let proposal: VoiceSplitProposal
    let recording: Recording
    let locked: Bool
    let playing: Bool
    let target: Speaker?
    let person: VoicePerson?
    var body: some View {
        let name = recording.speakers.first { $0.id == proposal.speakerID }?.label ?? String(localized: "Voix")
        let part = recording.splitParts(proposal.id)?.smaller ?? []
        let duration = speechLabel(part.reduce(0) { $0 + max(0, $1.end - $1.start) })
        HStack(spacing: 8) {
            Image(systemName: "person.2.wave.2").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.copper)
            Text(detail(name: name, duration: duration)).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.copper)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(playing ? "Arrêter" : "Écouter ces passages") { model.toggleSplitPartPlayback(proposal.id) }
                .buttonStyle(StudioButtonStyle(compact: true)).disabled(recording.audioChunks.isEmpty)
                .help("Écoute uniquement les passages qui seraient séparés de cette voix.")
            Button("Séparer") { model.acceptSplit(proposal.id) }.buttonStyle(StudioButtonStyle(compact: true)).disabled(locked)
                .help(target.map { String(localized: "Ces passages rejoignent \($0.label).") } ?? String(localized: "Ces passages deviennent une nouvelle voix. Annulable."))
            Button("Une seule personne") { model.dismissSplit(proposal.id) }.buttonStyle(StudioButtonStyle(compact: true)).disabled(locked)
                .help("Laisse la voix telle quelle et retire cette proposition.")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Studio.copper.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
    private func detail(name: String, duration: String) -> String {
        if let target { return String(localized: "\(name) semble regrouper deux personnes : \(duration) ressemblent à \(target.label).") }
        if let person { return String(localized: "\(name) semble regrouper deux personnes : \(duration) ressemblent à \(person.name).") }
        return String(localized: "\(name) semble regrouper deux personnes : \(duration) viennent d’une autre voix.")
    }
}

func sourceLabel(_ source: AudioSource) -> String { source == .mic ? String(localized: "micro") : String(localized: "système") }
func speechLabel(_ seconds: Double) -> String {
    let value = Int(seconds.rounded())
    return value < 60 ? String(localized: "\(value) s") : String(localized: "\(value / 60) min \(String(format: "%02d", value % 60))")
}
