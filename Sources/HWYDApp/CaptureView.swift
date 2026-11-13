import SwiftUI
import HWYDCore

struct CaptureView: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    var compact = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    if model.isCapturePaused {
                        Image(systemName: "pause.fill").font(.system(size: 8)).foregroundStyle(Studio.muted)
                        Text("En pause · rien n’est enregistré").font(.system(size: Studio.Size.body, weight: .medium)).foregroundStyle(Studio.muted)
                    } else {
                        Circle().fill(Studio.copper).frame(width: 7, height: 7)
                        // The demo is named here because the detached notepad has no banner.
                        Text(model.isDemoMode ? "Simulation" : "Enregistrement").font(.system(size: Studio.Size.body, weight: .medium)).foregroundStyle(Studio.copper)
                    }
                    Spacer()
                }
                TextField("Titre de la session", text: Binding(get: { model.activeCapture?.title ?? recording.title }, set: { value in model.update(recording.id) { $0.title = value } }))
                    .textFieldStyle(.plain).font(.system(size: compact ? Studio.Size.heading : Studio.Size.title, weight: .medium)).accessibilityLabel("Titre de la session en cours")
                HStack(spacing: 16) {
                    Picker("Type", selection: Binding(get: { model.activeCapture?.kind ?? .adHoc }, set: { value in model.update(recording.id) { $0.kind = value } })) {
                        ForEach(SessionKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 150)
                    Spacer(minLength: 8)
                    Toggle(isOn: Binding(get: { model.activeCapture?.consentAnnounced ?? false }, set: { value in model.update(recording.id) { $0.consentAnnounced = value } })) {
                        Text("J’ai informé les personnes présentes").font(.system(size: Studio.Size.body)).foregroundStyle(Studio.muted)
                    }.toggleStyle(.checkbox)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(timeLabel(model.elapsed, hours: true)).font(.system(size: compact ? 38 : 52, weight: .light, design: .monospaced)).tracking(-2)
                        .opacity(model.isCapturePaused ? 0.45 : 1)
                    Spacer()
                    if !compact { Button { model.openNotepad?() } label: { Label("Détacher les notes", systemImage: "macwindow.on.rectangle") }.buttonStyle(StudioButtonStyle()) }
                }
                if !compact {
                    HStack(spacing: 12) {
                        source(String(localized: "Micro"), symbol: "mic", level: model.micLevel)
                        source(String(localized: "Système"), symbol: "speaker.wave.2", level: model.systemLevel)
                    }
                }
                Divider().overlay(Studio.line)
                HStack(spacing: 10) {
                    Text("Notes").font(.system(size: Studio.Size.heading, weight: .medium))
                    NotesSaveStatus()
                    Spacer()
                    Button { model.addTimestamp() } label: { Label("Horodatage", systemImage: "plus") }.buttonStyle(StudioButtonStyle(compact: true)).keyboardShortcut("t", modifiers: [.command, .shift])
                }
                NotesEditor(recording: recording, headings: false)
            }.padding(compact ? 23 : 32)
        }.background(Studio.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer()
                Button { model.toggleCapturePause() } label: {
                    Label(model.isCapturePaused ? "Reprendre" : "Pause", systemImage: model.isCapturePaused ? "record.circle" : "pause.fill")
                }.buttonStyle(StudioButtonStyle(primary: model.isCapturePaused)).keyboardShortcut("p", modifiers: [.command, .shift])
                    .help(model.isCapturePaused ? "Reprendre l’enregistrement dans la même session" : "Suspendre l’enregistrement sans terminer la session. Micro et audio système sont coupés pendant la pause.")
                Button { model.stopCapture() } label: { Label("Terminer la session", systemImage: "stop.fill") }.buttonStyle(StudioButtonStyle(primary: true, destructive: true))
            }.padding(.horizontal, compact ? 23 : 32).padding(.vertical, 15).background(Studio.inset).overlay(alignment: .top) { Rectangle().fill(Studio.line).frame(height: 1) }
        }
    }
    private func source(_ name: String, symbol: String, level: Float) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(name, systemImage: symbol).font(.system(size: Studio.Size.caption, weight: .medium))
            WaveformView(level: level).frame(height: 45)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Studio.surface, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Studio.line))
    }
}
struct SpeakerEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    private var speaker: Speaker? { model.selected?.speakers.first { $0.id == model.editingSpeakerID } }
    private func confirm() { model.speakerName = name; model.confirmSpeaker() }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Nommer cette voix", systemImage: "person.crop.circle.badge.checkmark").font(.system(size: Studio.Size.heading, weight: .medium))
            Text("Le nom s’applique à cette voix dans toute la session. Mémorisez-la pour la reconnaître dans les prochaines.").font(.system(size: Studio.Size.body)).foregroundStyle(Studio.muted)
            TextField("Nom de la personne", text: $name).textFieldStyle(.roundedBorder).onSubmit { confirm() }
            Text("Mémoriser ajoute une empreinte de cette voix (20 secondes minimum) au trousseau de ce Mac. Faites-le seulement avec l’accord de la personne ; l’apport se retire dans Réglages › Audio et voix.").font(.caption).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Annuler") { model.editingSpeakerID = nil }.buttonStyle(StudioButtonStyle())
                Spacer()
                Button("Nommer seulement") { confirm() }.buttonStyle(StudioButtonStyle()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Nommer et mémoriser") {
                    if let speaker { model.rememberSpeaker(name: name, speakerID: speaker.id) }
                }.buttonStyle(StudioButtonStyle(primary: true)).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.workAvailability.isReady || model.isDemoMode || model.voiceEditingLocked)
            }
        }.padding(28).frame(width: 540).background(Studio.background).foregroundStyle(Studio.text).preferredColorScheme(model.appearancePreference.colorScheme)
            .onAppear { name = model.speakerName }
    }
}
