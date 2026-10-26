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
                    if recording.isDemo { Badge(text: "EXEMPLE") }
                    Button { model.exportSelected() } label: { Label("Exporter", systemImage: "square.and.arrow.up") }.buttonStyle(StudioButtonStyle())
                }
                TextField("Titre de la session", text: Binding(get: { model.selected?.title ?? recording.title }, set: { value in model.update(recording.id) { $0.title = value } }))
                    .textFieldStyle(.plain).font(.system(size: 28, weight: .semibold)).tracking(-0.6).accessibilityLabel("Titre de la session")
                HStack(spacing: 9) {
                    Text("\(max(1, Int(recording.duration / 60))) min")
                    if !recording.participantNames.isEmpty { Text("·"); Text(recording.participantNames) }
                    Spacer()
                    if recording.transcriptVersion > 0 { Text("Transcript v\(recording.transcriptVersion)") }
                }.font(.system(size: 11)).foregroundStyle(Studio.muted)
                if let event = recording.calendarContext {
                    Label("\(event.calendarTitle) · \(event.start.formatted(date: .abbreviated, time: .shortened)) · \(event.participants.count) invité(s)", systemImage: "calendar")
                        .font(.system(size: 11)).foregroundStyle(Studio.muted)
                }
                HStack {
                    Button("Identité des voix…") { model.showVoiceIdentity = true }.buttonStyle(StudioButtonStyle()).disabled(recording.isDemo || model.modelWorkBusy)
                    Spacer()
                }
                audioPlayer
                HStack(spacing: 26) {
                    ForEach(DetailTab.allCases, id: \.self) { tab in
                        Button { model.activeTab = tab } label: {
                            VStack(spacing: 12) {
                                HStack(spacing: 6) {
                                    Text(tab.rawValue)
                                    if tab == .transcript && !recording.segments.isEmpty { Text("\(recording.segments.count)").font(.system(size: 9)).foregroundStyle(Studio.muted) }
                                }.font(.system(size: 12, weight: model.activeTab == tab ? .medium : .regular))
                                Rectangle().fill(model.activeTab == tab ? Studio.mint : Color.clear).frame(height: 2)
                            }.foregroundStyle(model.activeTab == tab ? Studio.mint : Studio.muted)
                        }.buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer()
                }.overlay(alignment: .bottom) { Rectangle().fill(Studio.line).frame(height: 0.5) }
            }.padding(.horizontal, 32).padding(.top, 28)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    switch model.activeTab {
                    case .transcript: transcript
                    case .notes: NotesEditor(recording: recording)
                    case .summary: summary
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(32).padding(.top, 0)
            }
        }.background(Studio.background)
        .sheet(isPresented: $model.showVoiceIdentity) { VoiceIdentityView().environmentObject(model) }
        .sheet(item: $splittingSegment) { segment in
            SegmentSplitView(recordingID: recording.id, segment: segment).environmentObject(model)
        }
        .confirmationDialog("Remplacer le transcript ?", isPresented: $confirmReprocessing) {
            Button("Retranscrire") { model.transcribe(recording.id) }
            Button("Annuler", role: .cancel) {}
        } message: { Text("Les voix seront détectées à nouveau et les noms corrigés seront réinitialisés. Vos notes et les versions précédentes restent conservées.") }
    }
    private var audioPlayer: some View {
        SessionPlayerView(recording: recording)
            .task(id: recording.id) { await model.loadWaveforms(for: recording) }
    }
    @ViewBuilder private var transcript: some View {
        if !recording.isDemo {
            HStack {
                if recording.transcriptState == .pending {
                    ProgressView().controlSize(.small)
                    Text("Traitement audio local en cours…").font(.system(size: 12))
                    Spacer()
                    Button("Annuler") { model.cancelProcessing() }.buttonStyle(StudioButtonStyle())
                } else {
                    Text(recording.transcriptState == .failed ? "Le traitement a été interrompu ou a échoué." : (recording.transcription?.diarizationEngine == nil ? "Français · Apple Speech · sur ce Mac" : "Français · Apple Speech + Community-1")).font(.system(size: 11)).foregroundStyle(Studio.muted)
                    Spacer()
                    Button(recording.transcriptVersion > 0 ? "Retranscrire" : "Transcrire") { if recording.transcriptVersion > 0 { confirmReprocessing = true } else { model.transcribe(recording.id) } }
                        .buttonStyle(StudioButtonStyle()).disabled(model.modelWorkBusy || recording.audioChunks.isEmpty)
                }
            }
        }
        if recording.segments.isEmpty {
            EmptyPanel(symbol: "text.bubble", title: recording.transcriptState == .ready ? "Aucune parole reconnue" : "Votre transcript viendra ici", detail: recording.isDemo ? "Cet exemple ne contient pas de transcript." : "La transcription utilise les fichiers audio conservés. Vous pouvez continuer à écrire vos notes pendant le traitement.")
        } else {
            ForEach(recording.segments) { segment in
                let speaker = recording.speakers.first { $0.id == segment.speakerID }
                TranscriptRow(segment: segment, speaker: speaker,
                    candidates: recording.speakers.filter { $0.source == segment.source },
                    disabled: model.processingID == recording.id || recording.state == .recording,
                    onPlay: { model.play(at: segment.start) },
                    onEdit: { model.beginSpeakerEdit($0) },
                    onAssign: { model.assignSpeaker($0, to: segment.id, recordingID: recording.id) },
                    onSplit: { splittingSegment = segment }).equatable()
            }
            Label(recording.transcription?.echoCancellationEngine != nil ? "Écho du système atténué sur le micro avant transcription. Audio original conservé. Les empreintes mémorisées restent sur ce Mac." : recording.transcription?.diarizationEngine != nil ? "Voix séparées par piste. Rejet d’écho non appliqué. Les empreintes mémorisées restent sur ce Mac." : recording.speakers.isEmpty ? "Diarisation et rejet d’écho non appliqués à ce transcript." : "Nommer une voix ne crée pas d’empreinte vocale.", systemImage: "hand.raised").font(.system(size: 11)).foregroundStyle(Studio.muted).padding(.top, 6)
        }
    }
    @ViewBuilder private var summary: some View {
        if !recording.isDemo {
            HStack {
                Button(model.summaryID == recording.id ? "Génération…" : recording.summary == nil ? "Générer une synthèse" : "Régénérer") { model.generateSummary() }
                    .buttonStyle(StudioButtonStyle(primary: true)).disabled(!model.summaryEnabled || model.modelWorkBusy || recording.segments.isEmpty)
                if model.summaryID == recording.id { Button("Annuler") { model.cancelSummary() }.buttonStyle(StudioButtonStyle()) }
                Spacer()
                Button("Réglages du modèle") { model.settingsCategory = .summary; model.showSettings = true }.buttonStyle(StudioButtonStyle())
            }
            if model.summaryID == recording.id, let progress = model.summaryProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("\(progress.stage) · \(progress.completed) étapes terminées" + (progress.cached ? " · reprise du cache" : "")).font(.caption).foregroundStyle(Studio.muted)
                }
            }
            Text("Brouillon généré localement, à relire. Les décisions et actions gardent leurs références au transcript.").font(.system(size: 11)).foregroundStyle(Studio.muted)
            if let provenance = recording.summaryProvenance, recording.summary != nil {
                Text("\(provenance.model) · \(provenance.promptVersion) · transcript v\(provenance.transcriptVersion)").font(.system(size: 10)).foregroundStyle(Studio.muted)
            }
        }
        if let summary = recording.summary {
            if let structured = recording.summaryProvenance?.structured, structured.details != nil {
                summaryHeading("Résumé")
                summaryParagraph(structured.overview)
                summaryTopics(structured.key_points ?? [])
                if !structured.decisions.isEmpty {
                    summaryHeading("Décisions")
                    ForEach(Array(structured.decisions.enumerated()), id: \.offset) { _, decision in
                        summaryParagraph("• " + decision.text)
                        summaryReferences(decision.evidence_segment_ids)
                    }
                }
                if !structured.action_items.isEmpty {
                    summaryHeading("Étapes suivantes")
                    ForEach(Array(structured.action_items.enumerated()), id: \.offset) { _, action in
                        summaryParagraph("• " + (action.assignee_name.map { $0 + " : " } ?? "") + action.text + (action.due_date.map { " (" + $0 + ")" } ?? ""))
                        summaryReferences(action.evidence_segment_ids)
                    }
                }
                if let details = structured.details, !details.isEmpty {
                    summaryHeading("Détails")
                    summaryTopics(details)
                }
            } else {
            ForEach(Array(summary.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                if paragraph.hasPrefix("### ") { Text(String(paragraph.dropFirst(4))).font(.system(size: 14, weight: .semibold)).padding(.top, 6) }
                else if paragraph.hasPrefix("## ") { Text(paragraph.replacingOccurrences(of: "## ", with: "")).font(.system(size: 16, weight: .medium)).foregroundStyle(Studio.mint).padding(.top, 12) }
                else { Text(paragraph).font(.system(size: 14)).lineSpacing(7).textSelection(.enabled) }
            }
            }
            if recording.isDemo { Badge(text: "SYNTHÈSE FICTIVE · EXEMPLE D’INTERFACE").padding(.top, 15) }
        } else {
            EmptyPanel(symbol: "sparkles", title: model.summaryEnabled ? "Pas encore de synthèse" : "La synthèse est facultative", detail: model.summaryEnabled ? "Lancez la génération avec votre modèle local. Vos notes et votre transcript restent indépendants." : "Activez un modèle dans les réglages pour générer une synthèse.")
            Button("Voir les réglages") { model.settingsCategory = .summary; model.showSettings = true }.buttonStyle(StudioButtonStyle())
        }
    }
    private func summaryHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Studio.mint).padding(.top, 12)
    }
    private func summaryParagraph(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func summaryTopics(_ topics: [SummaryTopic]) -> some View {
        ForEach(Array(topics.enumerated()), id: \.offset) { _, topic in
            VStack(alignment: .leading, spacing: 8) {
                Text(topic.title).font(.system(size: 14, weight: .semibold))
                summaryParagraph(topic.text)
                summaryReferences(topic.evidence_segment_ids)
            }.padding(.vertical, 4)
        }
    }
    private func summaryReferences(_ ids: [UUID]) -> some View {
        HStack(spacing: 12) {
            ForEach(recording.segments.filter { ids.contains($0.id) }) { segment in
                Button(timeLabel(segment.start)) { model.seekPlayback(to: segment.start) }
                    .buttonStyle(.plain).font(.system(size: 11, design: .monospaced)).foregroundStyle(Studio.mint)
                    .help(segment.text)
            }
        }
    }
}
struct NotesEditor: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !recording.noteEntries.isEmpty {
                Eyebrow(text: "Pendant la conversation")
                ForEach(recording.noteEntries) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        Text(timeLabel(entry.offset)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.mint).frame(width: 45).padding(.top, 4)
                        TextField("Votre note…", text: Binding(get: { model.recordings.first { $0.id == recording.id }?.noteEntries.first { $0.id == entry.id }?.text ?? entry.text }, set: { value in
                            model.update(recording.id) { if let i = $0.noteEntries.firstIndex(where: { $0.id == entry.id }) { $0.noteEntries[i].text = value } }
                        }), axis: .vertical).textFieldStyle(.plain).font(.system(size: 13)).lineSpacing(5)
                    }.padding(12).background(Studio.surface, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack { Eyebrow(text: "Vos notes"); Spacer(); Text(model.isDemoMode ? "Exemple modifiable" : model.hasUnsavedChanges ? "Enregistrement…" : "Enregistré sur ce Mac").font(.system(size: 10)).foregroundStyle(Studio.muted) }
            TextEditor(text: Binding(get: { model.recordings.first { $0.id == recording.id }?.notes ?? recording.notes }, set: { value in model.update(recording.id) { $0.notes = value } }))
                .font(.system(size: 14)).lineSpacing(7).scrollContentBackground(.hidden).padding(12).frame(minHeight: 220)
                .background(Studio.inset, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Studio.line)).accessibilityLabel("Notes manuelles de la session")
        }
    }
}

// Playback ticks do not need to rebuild menus and selectable text for unchanged rows.
private struct TranscriptRow: View, Equatable {
    let segment: TranscriptSegment
    let speaker: Speaker?
    let candidates: [Speaker]
    let disabled: Bool
    let onPlay: () -> Void
    let onEdit: (Speaker) -> Void
    let onAssign: (UUID?) -> Void
    let onSplit: () -> Void
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.segment == rhs.segment && lhs.speaker == rhs.speaker && lhs.candidates == rhs.candidates && lhs.disabled == rhs.disabled
    }
    var body: some View {
                HStack(alignment: .top, spacing: 16) {
                    Button(timeLabel(segment.start)) { onPlay() }.buttonStyle(.plain).font(.system(size: 10, design: .monospaced)).foregroundStyle(Studio.muted).frame(width: 42).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 9) {
                        if let speaker {
                            Button { onEdit(speaker) } label: {
                                HStack(spacing: 6) {
                                    Text(speaker.label)
                                    if !speaker.confirmed { Image(systemName: "pencil"); Text(speaker.proposedIdentity == nil ? "à nommer" : "à confirmer") }
                                    else { Text("· \(speaker.source == .mic ? "micro" : "système")").foregroundStyle(Studio.muted) }
                                }.font(.system(size: 11, weight: .medium)).foregroundStyle(speaker.confirmed ? Studio.mint : Studio.copper)
                            }.buttonStyle(.plain).disabled(disabled).help("Corriger cette voix dans toute la session").accessibilityIdentifier("speaker-\(segment.id)")
                        }
                        if speaker == nil {
                            Text(segment.source == .mic ? "Micro · voix non attribuée" : "Système · voix non attribuée")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(Studio.muted)
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
                            Label("Corriger ce passage", systemImage: "person.crop.circle.badge.questionmark")
                                .font(.system(size: 10)).foregroundStyle(Studio.muted)
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(disabled)
                        .help("Changer le locuteur de ce passage sans modifier les autres passages")
                        if segment.echoSuspect == true {
                            Label("Écho possible · à vérifier", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 10)).foregroundStyle(Studio.copper)
                                .help("Ce passage ressemble à la piste système voisine. Le texte et son attribution sont conservés.")
                        }
                        Text(segment.text).font(.system(size: 13)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(Studio.surface, in: RoundedRectangle(cornerRadius: 7))
    }
}
