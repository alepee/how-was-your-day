import SwiftUI
import HWYDCore

struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    var compact = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack(spacing: 8) {
                    Circle().fill(Studio.copper).frame(width: 7, height: 7)
                    Text(model.isDemoMode ? "Simulation de session" : "Enregistrement en cours").font(.system(size: 12, weight: .medium)).foregroundStyle(Studio.copper)
                    Spacer()
                    if model.isDemoMode { Badge(text: "AUCUN AUDIO CAPTURÉ", color: Studio.copper) }
                }
                TextField("Titre de la session", text: Binding(get: { model.activeCapture?.title ?? recording.title }, set: { value in model.update(recording.id) { $0.title = value } }))
                    .textFieldStyle(.plain).font(.system(size: compact ? 23 : 30, weight: .medium)).accessibilityLabel("Titre de la session en cours")
                HStack {
                    Picker("Type", selection: Binding(get: { model.activeCapture?.kind ?? .adHoc }, set: { value in model.update(recording.id) { $0.kind = value } })) {
                        ForEach(SessionKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 150)
                    Text("Sans événement calendrier").font(.system(size: 11)).foregroundStyle(Studio.muted)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(timeLabel(model.elapsed, hours: true)).font(.system(size: compact ? 38 : 52, weight: .light, design: .monospaced)).tracking(-2)
                    Text(model.isDemoMode ? "simulées" : "enregistrées").font(.system(size: 11)).foregroundStyle(Studio.muted)
                    Spacer()
                    if !compact { Button { model.openNotepad?() } label: { Label("Détacher les notes", systemImage: "rectangle.on.rectangle") }.buttonStyle(StudioButtonStyle()) }
                }
                if !compact {
                    HStack(spacing: 12) {
                        source("Micro brut", subtitle: "Voix et salle", symbol: "mic", level: model.micLevel)
                        source("Audio système", subtitle: "Apps et appels", symbol: "speaker.wave.2", level: model.systemLevel)
                    }
                }
                Toggle(isOn: Binding(get: { model.activeCapture?.consentAnnounced ?? false }, set: { value in model.update(recording.id) { $0.consentAnnounced = value } })) {
                    Text("J’ai informé les personnes présentes.").font(.system(size: 12)).foregroundStyle(Studio.muted)
                }.toggleStyle(.checkbox)
                Divider().overlay(Studio.line)
                HStack { Text("Notes de session").font(.system(size: 14, weight: .medium)); Spacer(); Button { model.addTimestamp() } label: { Label("Horodatage", systemImage: "plus") }.buttonStyle(StudioButtonStyle()).keyboardShortcut("t", modifiers: [.command, .shift]) }
                NotesEditor(recording: recording)
                Text(model.isDemoMode ? "La simulation permet de tester le notepad sans activer le micro." : "L’audio brut est conservé localement. Aucun transcript n’est envoyé à un service externe.").font(.system(size: 11)).foregroundStyle(Studio.muted).lineSpacing(4)
            }.padding(compact ? 23 : 32)
        }.background(Studio.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Label(model.isDemoMode ? "Simulation" : "Sur ce Mac", systemImage: "lock").font(.system(size: 11)).foregroundStyle(Studio.muted)
                Spacer()
                Button { model.stopCapture() } label: { Label("Terminer la session", systemImage: "stop.fill") }.buttonStyle(StudioButtonStyle(primary: true, destructive: true))
            }.padding(.horizontal, compact ? 23 : 32).padding(.vertical, 15).background(Studio.inset).overlay(alignment: .top) { Rectangle().fill(Studio.line).frame(height: 1) }
        }
    }
    private func source(_ name: String, subtitle: String, symbol: String, level: Float) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label(name, systemImage: symbol).font(.system(size: 11, weight: .medium)); Spacer(); Text(subtitle).font(.system(size: 10)).foregroundStyle(Studio.muted) }
            WaveformView(level: level).frame(height: 45)
        }.padding(16).frame(maxWidth: .infinity).background(Studio.surface, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Studio.line))
    }
}
struct SpeakerEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var channel: VoiceChannel = .near
    private var speaker: Speaker? { model.selected?.speakers.first { $0.id == model.editingSpeakerID } }
    private func confirm() { model.speakerName = name; model.confirmSpeaker() }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Nommer cette voix", systemImage: "person.crop.circle.badge.checkmark").font(.system(size: 20, weight: .medium))
            Text("Le nom s’applique à cette voix dans toute la session. Mémorisez-la pour la reconnaître dans les prochaines.").font(.system(size: 13)).foregroundStyle(Studio.muted)
            TextField("Nom de la personne", text: $name).textFieldStyle(.roundedBorder).onSubmit { confirm() }
            if speaker?.source == .mic {
                Picker("Microphone", selection: $channel) {
                    Text("Proche · mon micro").tag(VoiceChannel.near)
                    Text("Salle · voix éloignée").tag(VoiceChannel.room)
                }
            }
            Text("L’empreinte utilise au moins 20 secondes de cette voix et reste dans le trousseau du Mac.").font(.caption).foregroundStyle(Studio.muted)
            HStack {
                Button("Annuler") { model.editingSpeakerID = nil }.buttonStyle(StudioButtonStyle())
                Spacer()
                Button("Nommer seulement") { confirm() }.buttonStyle(StudioButtonStyle()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Nommer et mémoriser") {
                    if let speaker { model.rememberSpeaker(name: name, speakerID: speaker.id, channel: speaker.source == .system ? .remote : channel) }
                }.buttonStyle(StudioButtonStyle(primary: true)).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.pipelineBusy || model.isDemoMode)
            }
        }.padding(28).frame(width: 540).background(Studio.background).foregroundStyle(Studio.text).preferredColorScheme(model.appearancePreference.colorScheme)
            .onAppear { name = model.speakerName; channel = speaker?.source == .system ? .remote : .near }
    }
}
