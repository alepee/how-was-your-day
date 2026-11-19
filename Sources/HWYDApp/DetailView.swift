import SwiftUI
import HWYDCore

struct DetailView: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    @State private var confirmReprocessing = false
    @State private var splittingSegment: TranscriptSegment?
    @State private var splittingVoiceAt: TranscriptSegment?
    @State private var exportFormat: SummaryExportFormat?
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Eyebrow(text: "\(recording.kind.label) · \(recording.startedAt.formatted(.dateTime.day().month(.wide)))")
                    Spacer()
                    if recording.isDemo { Badge(text: String(localized: "EXEMPLE")) }
                    ResumeRecordingButton(recording: recording)
                    Button { model.exportSelected() } label: { Label("Exporter", systemImage: "square.and.arrow.up") }.buttonStyle(StudioButtonStyle())
                }
                TextField("Titre de la session", text: Binding(get: { model.selected?.title ?? recording.title }, set: { value in model.update(recording.id) { $0.title = value } }))
                    .textFieldStyle(.plain).font(.system(size: Studio.Size.title, weight: .semibold)).tracking(-0.6).accessibilityLabel("Titre de la session")
                HStack(spacing: 9) {
                    Text("\(max(1, Int(recording.duration / 60))) min")
                    if !recording.participantNames.isEmpty { Text("·"); Text(recording.participantNames) }
                }.font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
                if let event = recording.calendarContext {
                    let guests = String(localized: "\(event.participants.count) invité(s)")
                    Label { Text(verbatim: "\(event.calendarTitle) · \(event.start.formatted(date: .abbreviated, time: .shortened)) · \(guests)") } icon: { Image(systemName: "calendar") }
                        .font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
                }
                audioPlayer
                VoiceTilesView(recording: recording)
                HStack(spacing: 26) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in
                        Button { model.activeTab = tab } label: {
                            VStack(spacing: 12) {
                                HStack(spacing: 6) {
                                    Text(tab.title)
                                    if tab == .transcript && !recording.segments.isEmpty { Text(recording.heardSegments.count, format: .number).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted) }
                                }.font(.system(size: Studio.Size.body, weight: model.activeTab == tab ? .medium : .regular))
                                Rectangle().fill(model.activeTab == tab ? Studio.mint : Color.clear).frame(height: 2)
                            }.foregroundStyle(model.activeTab == tab ? Studio.mint : Studio.muted).padding(.top, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer()
                }.overlay(alignment: .bottom) { Rectangle().fill(Studio.line).frame(height: 0.5) }
            }.padding(.horizontal, 32).padding(.top, 28)
            if model.activeTab == .transcript {
                TranscriptPane(recording: recording, header: transcriptHeader, onSplit: { splittingSegment = $0 }, onSplitVoice: { splittingVoiceAt = $0 })
            } else if model.activeTab == .summary {
                SummaryPane(recording: recording, header: summaryControls).id(recording.id)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 15) {
                        NotesEditor(recording: recording)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(32).padding(.top, 0)
                }
            }
        }.background(Studio.background)
        .sheet(item: $splittingSegment) { segment in
            SegmentSplitView(recordingID: recording.id, segment: segment).environmentObject(model)
        }
        .sheet(item: $splittingVoiceAt) { segment in
            VoiceSplitSheet(recording: recording, segment: segment) { side in
                splittingVoiceAt = nil
                // The name editor of the new voice opens once this sheet is gone.
                DispatchQueue.main.async { model.splitSpeaker(at: segment.id, keepingIdentity: side) }
            }.environmentObject(model)
        }
        .sheet(item: $exportFormat) { format in
            SummaryExportSheet(recording: recording, format: format) { sections in
                exportFormat = nil
                // The save panel opens once the sheet is gone.
                DispatchQueue.main.async { model.exportSummary(format, sections: sections) }
            }
        }
        .onChange(of: model.languageChoiceID) { _, _ in openLanguageChoice() }
        .onAppear(perform: openLanguageChoice)
        .confirmationDialog("Remplacer le transcript ?", isPresented: $confirmReprocessing) {
            Button("Retranscrire") { model.transcribe(recording.id) }
            ForEach(model.sessionLanguageChoices.filter { $0 != (recording.speechLanguage ?? SpeechLanguage.defaultLocale) }, id: \.self) { choice in
                Button(choice == SpeechLanguage.automatic ? "Retranscrire avec détection automatique" : "Retranscrire en \(SpeechLanguage.displayName(choice))") { model.transcribe(recording.id, language: choice) }
            }
            Button("Annuler", role: .cancel) {}
        } message: { Text("Les voix seront détectées à nouveau et les noms corrigés seront réinitialisés. Vos notes et les versions précédentes restent conservées.") }
    }
    /// A detection notice asked to choose this session's language.
    private func openLanguageChoice() {
        guard model.languageChoiceID == recording.id else { return }
        model.languageChoiceID = nil; model.refreshSpeechLanguages(); confirmReprocessing = true
    }
    private var audioPlayer: some View {
        SessionPlayerView(recording: recording)
            .task(id: recording.id) { await model.loadWaveforms(for: recording) }
    }
    @ViewBuilder private var transcriptHeader: some View {
        if !recording.isDemo {
            HStack {
                if recording.transcriptState == .pending || model.work.isQueued(.transcription(session: recording.id)) {
                    ProgressView().controlSize(.small)
                    if recording.transcriptState == .pending {
                        Text("Traitement audio local en cours…").font(.system(size: Studio.Size.body))
                    } else {
                        Text("Transcription en attente : elle démarrera après le traitement en cours.").font(.system(size: Studio.Size.body))
                    }
                    Spacer()
                    Button("Annuler") { model.cancelTranscription(recording.id) }.buttonStyle(StudioButtonStyle())
                } else {
                    Text(recording.transcriptState == .failed ? String(localized: "Le traitement a été interrompu ou a échoué.") : (recording.transcription.map { SessionLanguageLabel.transcript($0) + ($0.diarizationEngine == nil ? String(localized: " · Apple Speech · sur ce Mac") : " · Apple Speech + Community-1") } ?? SessionLanguageLabel.title(recording.speechLanguage ?? SpeechLanguage.defaultLocale) + String(localized: " · Apple Speech · sur ce Mac"))).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
                    Spacer()
                    Button(recording.transcriptVersion > 0 ? "Retranscrire" : "Transcrire") { if recording.transcriptVersion > 0 { model.refreshSpeechLanguages(); confirmReprocessing = true } else { model.transcribe(recording.id) } }
                        .buttonStyle(StudioButtonStyle()).disabled(recording.audioChunks.isEmpty) // Queued behind other work.
                }
            }
        }
    }
    /// Generation controls above the summary, or the empty state when there is none yet.
    @ViewBuilder private var summaryControls: some View {
        if !recording.isDemo {
            let queued = model.work.isQueued(.summary(session: recording.id))
            HStack {
                Button(model.summaryID == recording.id ? "Génération…" : queued ? "En attente…" : recording.summary == nil ? "Générer une synthèse" : "Régénérer") { model.generateSummary() }
                    .buttonStyle(StudioButtonStyle(primary: true)).disabled(!model.summaryAvailability.isReady || recording.segments.isEmpty)
                if model.summaryID == recording.id || queued { Button("Annuler") { model.cancelSummary(of: recording.id) }.buttonStyle(StudioButtonStyle()) }
                if recording.summary != nil {
                    Menu {
                        Button("PDF…") { exportFormat = .pdf }
                        Button("Markdown…") { exportFormat = .markdown }
                    } label: { Label("Exporter la synthèse", systemImage: "square.and.arrow.up") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(model.summaryID == recording.id)
                }
                Spacer()
                Button("Réglages du modèle") { model.settingsCategory = .summary; model.showSettings = true }.buttonStyle(StudioButtonStyle())
            }
            if recording.summary == nil { unidentifiedVoicesNotice }
            if model.summaryID == recording.id, let progress = model.summaryProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: [progress.stage, String(localized: "\(progress.completed) étapes terminées"), progress.cached ? String(localized: "reprise du cache") : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Studio.muted)
                }
            }
            if case .unavailable(let reason) = model.summaryAvailability, reason != .disabled {
                Label(reason.localizedDescription, systemImage: "exclamationmark.circle").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
            }
            Label(model.summaryDisclosure.label, systemImage: "info.circle").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
                .help(summaryHint)
            if recording.summary != nil {
                unidentifiedVoicesNotice
                if recording.summaryIsStale {
                    // Corrections keep the summary; regenerating it, with the button above, is the user's decision.
                    Label("Le transcript a changé depuis cette synthèse.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.copper)
                }
            }
        }
        if recording.summary == nil {
            EmptyPanel(symbol: "sparkles", title: model.summaryAvailability != .unavailable(.disabled) ? String(localized: "Pas encore de synthèse") : String(localized: "La synthèse est facultative"), detail: model.summaryDisclosure.detail)
            Button("Voir les réglages") { model.settingsCategory = .summary; model.showSettings = true }.buttonStyle(StudioButtonStyle())
        }
    }
    /// Voices the user has not named, confirmed or ignored yet: a summary calls them generically.
    /// Information only; the voice tiles above are where they are named.
    @ViewBuilder private var unidentifiedVoicesNotice: some View {
        if !recording.segments.isEmpty, !recording.voicesResolved {
            Label("Des voix ne sont pas encore identifiées : la synthèse les désigne de façon générique.", systemImage: "person.crop.circle.badge.questionmark")
                .font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.copper)
        }
    }
    private var summaryHint: String {
        var text = String(localized: "Brouillon généré par un modèle. Les décisions et actions gardent leurs références au transcript.")
        if recording.summary != nil, let provenance = recording.summaryProvenance {
            text += "\n\(provenance.model) · \(provenance.promptVersion)"
        }
        return text
    }
}
/// Resumes recording in the session. Hidden where it can never apply (an example, past 24 hours),
/// disabled with the reason while a capture or work on the session keeps it from starting.
struct ResumeRecordingButton: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    var body: some View {
        let refusal = model.resumeRefusal(for: recording)
        if refusal?.hidesAction != true {
            Button { model.requestResume(recording) } label: { Label("Reprendre l’enregistrement", systemImage: "record.circle") }
                .buttonStyle(StudioButtonStyle()).disabled(refusal != nil)
                .help(refusal?.localizedDescription ?? String(localized: "Enregistrer la suite de cette session, après l’audio déjà enregistré."))
        }
    }
}
/// Where recording resumed in the transcript, before the first passage that follows.
struct ResumeMarker: View {
    let resume: CaptureBoundary
    var body: some View {
        HStack(spacing: 16) {
            Text(timeLabel(resume.offset)).font(.system(size: Studio.Size.caption, design: .monospaced)).foregroundStyle(Studio.muted)
                .frame(width: 46, alignment: .leading)
            Label(SessionResume.label(resume), systemImage: "record.circle").font(.system(size: Studio.Size.caption, weight: .medium)).foregroundStyle(Studio.copper)
            Rectangle().fill(Studio.line).frame(height: 0.5)
        }.padding(.horizontal, 17).padding(.vertical, 4).accessibilityElement(children: .combine)
    }
}
/// Where the notes stand: example, saving or saved on this Mac.
struct NotesSaveStatus: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Text(model.isDemoMode ? "Exemple modifiable" : model.hasUnsavedChanges ? "Enregistrement…" : "Enregistré sur ce Mac").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
    }
}
struct NotesEditor: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    /// The capture screen has its own "Notes" header, so it hides the section headings.
    var headings = true
    var body: some View {
        VStack(alignment: .leading, spacing: headings ? 18 : 10) {
            if !recording.noteEntries.isEmpty {
                if headings { Eyebrow(text: String(localized: "Pendant la conversation")) }
                ForEach(recording.noteEntries) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Text(timeLabel(entry.offset)).font(.system(size: Studio.Size.caption, design: .monospaced)).foregroundStyle(Studio.mint).frame(width: 45).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 8) {
                            if let image = entry.image { NoteImageView(recordingID: recording.id, image: image) }
                            TextField(entry.image == nil ? "Votre note…" : "Légende…", text: Binding(get: { model.recordings.first { $0.id == recording.id }?.noteEntries.first { $0.id == entry.id }?.text ?? entry.text }, set: { value in
                                model.update(recording.id) { if let i = $0.noteEntries.firstIndex(where: { $0.id == entry.id }) { $0.noteEntries[i].text = value } }
                            }), axis: .vertical).textFieldStyle(.plain).font(.system(size: entry.image == nil ? Studio.Size.body : Studio.Size.caption)).lineSpacing(5)
                        }
                        if entry.image != nil {
                            Button { model.removeNoteEntry(entry.id, from: recording.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).foregroundStyle(Studio.muted).help("Retirer l’image des notes").accessibilityLabel("Retirer l’image des notes")
                        }
                    }.padding(12).background(Studio.surface, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if headings { HStack { Eyebrow(text: String(localized: "Vos notes")); Spacer(); NotesSaveStatus() } }
            TextEditor(text: Binding(get: { model.recordings.first { $0.id == recording.id }?.notes ?? recording.notes }, set: { value in model.update(recording.id) { $0.notes = value } }))
                .font(.system(size: Studio.Size.body)).lineSpacing(7).scrollContentBackground(.hidden).padding(12).frame(minHeight: 220)
                .background(Studio.inset, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Studio.line)).accessibilityLabel("Notes manuelles de la session")
        }
    }
}

/// An image of the notes, at most as wide as the column and 320 pt high.
struct NoteImageView: View {
    @EnvironmentObject var model: AppModel
    let recordingID: UUID
    let image: NoteImage
    @State private var picture: NSImage?
    var body: some View {
        let ratio = CGFloat(image.width) / CGFloat(max(image.height, 1))
        Group {
            if let picture {
                Image(nsImage: picture).resizable().aspectRatio(ratio, contentMode: .fit)
            } else {
                Rectangle().fill(Studio.inset).aspectRatio(ratio, contentMode: .fit)
                    .overlay { Image(systemName: "photo").foregroundStyle(Studio.muted) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 320, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 5)).overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Studio.line))
        .accessibilityLabel("Image collée dans les notes")
        .task(id: image.id) { picture = await model.noteImageData(image, in: recordingID).flatMap(NSImage.init(data:)) }
    }
}

/// Transcript with playback follow. Reads only `activeSegmentIDs`, so the 5 Hz clock does not rebuild it.
private struct TranscriptPane<Header: View>: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    let header: Header
    let onSplit: (TranscriptSegment) -> Void
    let onSplitVoice: (TranscriptSegment) -> Void
    @State private var following = true
    var body: some View {
        let playback = model.playback
        let active = playback.activeSegmentIDs
        let playing = playback.isPlaying
        // One lookup table per render instead of a linear search per row.
        let speakers = Dictionary(recording.speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = Dictionary(grouping: recording.speakers.filter { !$0.ignored }, by: \.source)
        let heard = recording.heardSegments
        // A voice splits before any of its passages but the first.
        let firstPassages = Set(Dictionary(grouping: recording.segments.filter { $0.speakerID != nil }, by: \.speakerID)
            .values.compactMap { $0.min { $0.start < $1.start }?.id })
        let hidden = recording.segments.count - heard.count
        let disabled = model.processingID == recording.id || recording.state == .recording
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    header
                    if recording.segments.isEmpty {
                        EmptyPanel(symbol: "text.bubble", title: recording.transcriptState == .ready ? String(localized: "Aucune parole reconnue") : String(localized: "Votre transcript viendra ici"), detail: recording.isDemo ? String(localized: "Cet exemple ne contient pas de transcript.") : String(localized: "La transcription utilise les fichiers audio conservés. Vous pouvez continuer à écrire vos notes pendant le traitement."))
                    } else {
                        let markers = SessionResume.markers(recording.boundaries, before: heard.sorted { $0.start < $1.start })
                        ForEach(heard) { segment in
                            ForEach(markers[segment.id] ?? [], id: \.offset) { ResumeMarker(resume: $0) }
                            TranscriptRow(segment: segment, speaker: segment.speakerID.flatMap { speakers[$0] },
                                candidates: candidates[segment.source] ?? [],
                                canSplitVoice: segment.speakerID != nil && !firstPassages.contains(segment.id),
                                disabled: disabled, isActive: active.contains(segment.id),
                                onPlay: { model.play(at: segment.start) },
                                onEdit: { model.beginSpeakerEdit($0) },
                                onAssign: { model.assignSpeaker($0, to: segment.id, recordingID: recording.id) },
                                onSplit: { onSplit(segment) },
                                onNewVoice: { model.assignNewSpeaker(to: segment.id) },
                                onSplitVoice: { onSplitVoice(segment) }).equatable().id(segment.id)
                        }
                        if hidden > 0 {
                            Label("\(hidden) passage(s) masqué(s)", systemImage: "eye.slash")
                                .font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).padding(.top, 6)
                                .help("Passages de voix ignorées. Rétablissez la voix depuis sa tuile pour les revoir.")
                        }
                        HStack(spacing: 2) {
                            Text("À propos de ce transcript").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
                            HelpButton(text: footnote)
                        }.padding(.top, 2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(32).padding(.top, 0)
            }
            // A user scroll during playback pauses the follow; programmatic scrolls report `.animating`.
            .onScrollPhaseChange { _, phase in
                if phase == .interacting, model.playback.isPlaying { following = false }
            }
            .onChange(of: active) { _, ids in if following, playing { scroll(proxy, to: ids) } }
            .onChange(of: playback.generation) { _, _ in following = true; scroll(proxy, to: model.playback.activeSegmentIDs) }
            .overlay(alignment: .bottomTrailing) {
                if !following && playing {
                    Button { following = true; scroll(proxy, to: model.playback.activeSegmentIDs) } label: {
                        Label("Suivre la lecture", systemImage: "arrow.down.to.line")
                    }.buttonStyle(StudioButtonStyle(primary: true)).padding(20)
                        .help("Revenir au passage en cours de lecture")
                        .transition(.opacity)
                }
            }
        }
    }
    private func scroll(_ proxy: ScrollViewProxy, to ids: Set<UUID>) {
        guard let target = recording.heardSegments.first(where: { ids.contains($0.id) })?.id else { return }
        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.3)) }
    }
    private var footnote: String {
        recording.transcription?.echoCancellationEngine != nil ? String(localized: "Écho du système atténué sur le micro avant transcription. Audio original conservé. Les empreintes mémorisées restent sur ce Mac.") : recording.transcription?.diarizationEngine != nil ? String(localized: "Voix séparées par piste. Rejet d’écho non appliqué. Les empreintes mémorisées restent sur ce Mac.") : recording.speakers.isEmpty ? String(localized: "Diarisation et rejet d’écho non appliqués à ce transcript.") : String(localized: "Nommer une voix ne crée pas d’empreinte vocale.")
    }
}

// Playback ticks do not need to rebuild menus and selectable text for unchanged rows.
private struct TranscriptRow: View, Equatable {
    let segment: TranscriptSegment
    let speaker: Speaker?
    let candidates: [Speaker]
    let canSplitVoice: Bool
    let disabled: Bool
    let isActive: Bool
    let onPlay: () -> Void
    let onEdit: (Speaker) -> Void
    let onAssign: (UUID?) -> Void
    let onSplit: () -> Void
    let onNewVoice: () -> Void
    let onSplitVoice: () -> Void
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.segment == rhs.segment && lhs.speaker == rhs.speaker && lhs.candidates == rhs.candidates && lhs.canSplitVoice == rhs.canSplitVoice && lhs.disabled == rhs.disabled && lhs.isActive == rhs.isActive
    }
    var body: some View {
                HStack(alignment: .top, spacing: 16) {
                    Button { onPlay() } label: {
                        Text(timeLabel(segment.start)).font(.system(size: Studio.Size.caption, design: .monospaced))
                            .foregroundStyle(isActive ? Studio.mint : Studio.muted)
                            .frame(width: 46, height: 26, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.top, 1).help("Lire à partir de ce passage")
                    VStack(alignment: .leading, spacing: 7) {
                        if let speaker {
                            Button { onEdit(speaker) } label: {
                                HStack(spacing: 6) {
                                    Text(speaker.label)
                                    if !speaker.confirmed { Image(systemName: "pencil"); Text(speaker.proposedIdentity == nil ? "à nommer" : "à confirmer") }
                                }.font(.system(size: Studio.Size.caption, weight: .medium)).foregroundStyle(speaker.confirmed ? Studio.mint : Studio.copper)
                                    .padding(.vertical, 3).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(disabled).help("Corriger cette voix dans toute la session").accessibilityIdentifier("speaker-\(segment.id)")
                        } else {
                            Text(segment.source == .mic ? "Micro · voix non attribuée" : "Système · voix non attribuée")
                                .font(.system(size: Studio.Size.caption, weight: .medium)).foregroundStyle(Studio.muted)
                        }
                        if segment.echoSuspect == true {
                            Label("Écho possible · à vérifier", systemImage: "exclamationmark.triangle")
                                .font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.copper)
                                .help("Ce passage ressemble à la piste système voisine. Le texte et son attribution sont conservés.")
                        }
                        Text(segment.text).font(.system(size: Studio.Size.body)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Menu {
                        Text("Attribuer ce passage")
                        ForEach(candidates) { candidate in
                            Button {
                                onAssign(candidate.id)
                            } label: {
                                if segment.speakerID == candidate.id { Label(candidate.label, systemImage: "checkmark") }
                                else { Text(candidate.label) }
                            }
                        }
                        Button("Nouvelle voix…") { onNewVoice() }
                        Divider()
                        Button("Découper le passage…") { onSplit() }
                            .disabled(segment.splitIndices.isEmpty)
                        Button("Scinder la voix à partir d’ici…") { onSplitVoice() }
                            .disabled(!canSplitVoice)
                        Button("Voix non attribuée") {
                            onAssign(nil)
                        }.disabled(segment.speakerID == nil)
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 14)).foregroundStyle(Studio.muted)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(disabled)
                    .help("Corriger ce passage : changer de voix, le découper ou scinder sa voix")
                    .accessibilityLabel("Corriger ce passage")
                }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                    .background(isActive ? Studio.mint.opacity(0.1) : Studio.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isActive ? Studio.mint.opacity(0.6) : .clear))
                    .overlay(alignment: .leading) { if isActive { Rectangle().fill(Studio.mint).frame(width: 3).padding(.vertical, 10) } }
                    .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
