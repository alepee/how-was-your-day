import SwiftUI
import HWYDCore

struct DetailView: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    @State private var confirmReprocessing = false
    @State private var splittingSegment: TranscriptSegment?
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 17) {
                HStack {
                    Eyebrow(text: "\(recording.kind.label) · \(recording.startedAt.formatted(.dateTime.day().month(.wide)))")
                    Spacer()
                    if recording.isDemo { Badge(text: String(localized: "EXEMPLE")) }
                    Button { model.exportSelected() } label: { Label("Exporter", systemImage: "square.and.arrow.up") }.buttonStyle(StudioButtonStyle())
                }
                TextField("Titre de la session", text: Binding(get: { model.selected?.title ?? recording.title }, set: { value in model.update(recording.id) { $0.title = value } }))
                    .textFieldStyle(.plain).font(.system(size: Studio.Size.title, weight: .semibold)).tracking(-0.6).accessibilityLabel("Titre de la session")
                HStack(spacing: 9) {
                    Text("\(max(1, Int(recording.duration / 60))) min")
                    if !recording.participantNames.isEmpty { Text("·"); Text(recording.participantNames) }
                    Spacer()
                    if recording.transcriptVersion > 0 { Text("Transcript v\(recording.transcriptVersion)") }
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
                TranscriptPane(recording: recording, header: transcriptHeader, onSplit: { splittingSegment = $0 })
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
            HStack {
                Button(model.summaryID == recording.id ? "Génération…" : recording.summary == nil ? "Générer une synthèse" : "Régénérer") { model.generateSummary() }
                    .buttonStyle(StudioButtonStyle(primary: true)).disabled(!model.summaryAvailability.isReady || recording.segments.isEmpty)
                if model.summaryID == recording.id { Button("Annuler") { model.cancelSummary() }.buttonStyle(StudioButtonStyle()) }
                if recording.summary != nil {
                    Menu {
                        Button("PDF…") { model.exportSummary(.pdf) }
                        Button("Markdown…") { model.exportSummary(.markdown) }
                    } label: { Label("Exporter la synthèse", systemImage: "square.and.arrow.up") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(model.summaryID == recording.id)
                }
                Spacer()
                Button("Réglages du modèle") { model.settingsCategory = .summary; model.showSettings = true }.buttonStyle(StudioButtonStyle())
            }
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
        }
        if recording.summary == nil {
            EmptyPanel(symbol: "sparkles", title: model.summaryAvailability != .unavailable(.disabled) ? String(localized: "Pas encore de synthèse") : String(localized: "La synthèse est facultative"), detail: model.summaryDisclosure.detail)
            Button("Voir les réglages") { model.settingsCategory = .summary; model.showSettings = true }.buttonStyle(StudioButtonStyle())
        }
    }
    private var summaryHint: String {
        var text = String(localized: "Brouillon généré par un modèle. Les décisions et actions gardent leurs références au transcript.")
        if recording.summary != nil, let provenance = recording.summaryProvenance {
            text += "\n\(provenance.model) · \(provenance.promptVersion) · transcript v\(provenance.transcriptVersion)"
        }
        return text
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
                        TextField("Votre note…", text: Binding(get: { model.recordings.first { $0.id == recording.id }?.noteEntries.first { $0.id == entry.id }?.text ?? entry.text }, set: { value in
                            model.update(recording.id) { if let i = $0.noteEntries.firstIndex(where: { $0.id == entry.id }) { $0.noteEntries[i].text = value } }
                        }), axis: .vertical).textFieldStyle(.plain).font(.system(size: Studio.Size.body)).lineSpacing(5)
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

/// Transcript with playback follow. Reads only `activeSegmentIDs`, so the 5 Hz clock does not rebuild it.
private struct TranscriptPane<Header: View>: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    let header: Header
    let onSplit: (TranscriptSegment) -> Void
    @State private var following = true
    var body: some View {
        let playback = model.playback
        let active = playback.activeSegmentIDs
        let playing = playback.isPlaying
        // One lookup table per render instead of a linear search per row.
        let speakers = Dictionary(recording.speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = Dictionary(grouping: recording.speakers.filter { !$0.ignored }, by: \.source)
        let heard = recording.heardSegments
        let hidden = recording.segments.count - heard.count
        let disabled = model.processingID == recording.id || recording.state == .recording
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    header
                    if recording.segments.isEmpty {
                        EmptyPanel(symbol: "text.bubble", title: recording.transcriptState == .ready ? String(localized: "Aucune parole reconnue") : String(localized: "Votre transcript viendra ici"), detail: recording.isDemo ? String(localized: "Cet exemple ne contient pas de transcript.") : String(localized: "La transcription utilise les fichiers audio conservés. Vous pouvez continuer à écrire vos notes pendant le traitement."))
                    } else {
                        ForEach(heard) { segment in
                            TranscriptRow(segment: segment, speaker: segment.speakerID.flatMap { speakers[$0] },
                                candidates: candidates[segment.source] ?? [],
                                disabled: disabled, isActive: active.contains(segment.id),
                                onPlay: { model.play(at: segment.start) },
                                onEdit: { model.beginSpeakerEdit($0) },
                                onAssign: { model.assignSpeaker($0, to: segment.id, recordingID: recording.id) },
                                onSplit: { onSplit(segment) }).equatable().id(segment.id)
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
    let disabled: Bool
    let isActive: Bool
    let onPlay: () -> Void
    let onEdit: (Speaker) -> Void
    let onAssign: (UUID?) -> Void
    let onSplit: () -> Void
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.segment == rhs.segment && lhs.speaker == rhs.speaker && lhs.candidates == rhs.candidates && lhs.disabled == rhs.disabled && lhs.isActive == rhs.isActive
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
                        Divider()
                        Button("Découper le passage…") { onSplit() }
                            .disabled(segment.splitIndices.isEmpty)
                        Button("Voix non attribuée") {
                            onAssign(nil)
                        }.disabled(segment.speakerID == nil)
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 14)).foregroundStyle(Studio.muted)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(disabled)
                    .help("Corriger ce passage : changer de voix ou le découper")
                    .accessibilityLabel("Corriger ce passage")
                }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                    .background(isActive ? Studio.mint.opacity(0.1) : Studio.surface, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isActive ? Studio.mint.opacity(0.6) : .clear))
                    .overlay(alignment: .leading) { if isActive { Rectangle().fill(Studio.mint).frame(width: 3).padding(.vertical, 10) } }
                    .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
