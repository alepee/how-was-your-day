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
                    Picker("Type", selection: Binding(get: { model.activeCapture?.kind ?? .exchange }, set: { value in model.update(recording.id) { $0.kind = value } })) {
                        ForEach(SessionKind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(width: 150)
                    Spacer(minLength: 8)
                    Toggle(isOn: Binding(get: { model.activeCapture?.consentAnnounced ?? false }, set: { value in model.update(recording.id) { $0.consentAnnounced = value; $0.consentAnnouncedAt = value ? Date() : nil } })) {
                        Text("J’ai informé les personnes présentes").font(.system(size: Studio.Size.body)).foregroundStyle(Studio.muted)
                    }.toggleStyle(.checkbox)
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(timeLabel(model.elapsed, hours: true)).font(.system(size: compact ? 38 : 52, weight: .light, design: .monospaced)).tracking(-2)
                        .opacity(model.isCapturePaused ? 0.45 : 1)
                    Spacer()
                    if !compact { Button { model.openNotepad?() } label: { Label("Détacher les notes", systemImage: "macwindow.on.rectangle") }.buttonStyle(StudioButtonStyle()) }
                }
                if let prompt = model.inactivityPrompt { InactivityCallout(prompt: prompt) }
                if let offer = model.microphoneOffer { MicrophoneOfferCallout(offer: offer) }
                microphoneRow
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
                    Button { if !model.pasteNoteImage() { model.notifier.notify(.info(String(localized: "Aucune image dans le presse-papiers."))) } } label: { Label("Image", systemImage: "photo.badge.plus") }
                        .buttonStyle(StudioButtonStyle(compact: true)).help("Ajoute l’image du presse-papiers aux notes, à l’instant présent. ⌘V fonctionne aussi, comme le glisser-déposer.")
                    Button { model.addTimestamp() } label: { Label("Horodatage", systemImage: "plus") }.buttonStyle(StudioButtonStyle(compact: true)).keyboardShortcut("t", modifiers: [.command, .shift])
                }
                NotesEditor(recording: recording, headings: false)
                    .dropDestination(for: Data.self) { items, _ in
                        let images = items.filter { NSImage(data: $0) != nil }
                        images.forEach(model.addNoteImage)
                        return !images.isEmpty
                    }
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
    /// The microphone recorded, which the user can change at any time.
    @ViewBuilder private var microphoneRow: some View {
        if !model.captureMicrophones.devices.isEmpty || model.captureMicrophone != nil {
            HStack(spacing: 8) {
                Image(systemName: "mic").foregroundStyle(Studio.muted)
                Text("Micro").font(.system(size: Studio.Size.body)).foregroundStyle(Studio.muted)
                MicrophonePicker(devices: devices, selection: model.captureMicrophone?.uid, disabled: model.isSwitchingMicrophone) { model.chooseMicrophone($0) }
                    .accessibilityLabel("Micro enregistré")
                if model.isSwitchingMicrophone { ProgressView().controlSize(.small) }
                Spacer()
            }
        }
    }
    /// The inputs present, with the one recorded even while the list is being read again.
    private var devices: [MicrophoneDevice] {
        let list = model.captureMicrophones.devices
        guard let current = model.captureMicrophone, !list.contains(where: { $0.uid == current.uid }) else { return list }
        return [current] + list
    }
    private func source(_ name: String, symbol: String, level: Float) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(name, systemImage: symbol).font(.system(size: Studio.Size.caption, weight: .medium))
            WaveformView(level: level).frame(height: 45)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Studio.surface, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Studio.line))
    }
}
/// The microphone the system proposed while recording, until the user answers. Not answering
/// keeps the microphone in use.
struct MicrophoneOfferCallout: View {
    @EnvironmentObject var model: AppModel
    let offer: MicrophoneOffer
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: offer.device.transport == .bluetooth ? "headphones" : "mic.badge.plus").foregroundStyle(Studio.copper).frame(width: 18)
            VStack(alignment: .leading, spacing: 8) {
                Text("Nouveau micro disponible : \(offer.device.name)").font(.system(size: Studio.Size.body, weight: .semibold))
                Text(MicrophoneText.offer(offer)).font(.system(size: Studio.Size.body)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Basculer") { model.acceptMicrophoneOffer() }.buttonStyle(StudioButtonStyle(primary: true, compact: true))
                    Button(offer.current.map { String(localized: "Garder \($0)") } ?? String(localized: "Garder le micro actuel")) { model.declineMicrophoneOffer() }
                        .buttonStyle(StudioButtonStyle(compact: true))
                }.disabled(model.isSwitchingMicrophone)
            }
            Spacer(minLength: 0)
        }
        .padding(14).background(Studio.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) { UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7).fill(Studio.copper).frame(width: 3) }
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Studio.line))
        .accessibilityElement(children: .contain)
    }
}
/// « Vous avez fini ? »: nobody spoke for a while. The countdown runs until the capture stops on
/// its own; speech or an answer withdraws it.
struct InactivityCallout: View {
    @EnvironmentObject var model: AppModel
    let prompt: InactivityPrompt
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.slash").foregroundStyle(Studio.copper).frame(width: 18)
            VStack(alignment: .leading, spacing: 8) {
                Text("Vous avez fini ?").font(.system(size: Studio.Size.body, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, prompt.stopsAt.timeIntervalSince(context.date))
                    Text("Personne n’a parlé depuis \(InactivityText.minutes(prompt.silence)) min. Arrêt dans \(timeLabel(left, hours: false)).")
                        .font(.system(size: Studio.Size.body)).foregroundStyle(Studio.muted).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Pas encore") { model.keepRecording() }.buttonStyle(StudioButtonStyle(primary: true, compact: true))
                    Button("Arrêter") { model.stopCapture() }.buttonStyle(StudioButtonStyle(destructive: true, compact: true))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14).background(Studio.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .leading) { UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 7).fill(Studio.copper).frame(width: 3) }
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Studio.line))
        .accessibilityElement(children: .contain)
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
