import SwiftUI
import HWYDCore

/// Set up a session before recording: its kind and an optional name. Nothing is captured until
/// the user presses the start button.
struct NewSessionView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var nameFocused: Bool
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 10)]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 9) {
                    Eyebrow(text: String(localized: "Nouvelle session"))
                    Text("Que voulez-vous enregistrer ?").font(.system(size: Studio.Size.title, weight: .semibold)).tracking(-0.7)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: String(localized: "Type"))
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(SessionKind.allCases, id: \.self) { kind in kindTile(kind) }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Eyebrow(text: String(localized: "Nom"))
                        HelpButton(text: String(localized: "Facultatif. Sans nom, la session s’appelle d’après son type et l’heure de début. Vous pourrez le changer ensuite."))
                    }
                    TextField("Nom", text: $model.newSessionTitle, prompt: Text(NewSessionView.placeholder(model.newSessionKind)).foregroundStyle(Studio.muted))
                        .textFieldStyle(.plain).font(.system(size: Studio.Size.heading))
                        .padding(12).background(Studio.inset, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Studio.line))
                        .focused($nameFocused).onSubmit(start).frame(maxWidth: 520)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Eyebrow(text: String(localized: "Langue"))
                        HelpButton(text: String(localized: "En détection automatique, HWYD choisit la langue de chaque piste parmi les langues installées, d’après le début de l’enregistrement. Choisissez une langue pour l’imposer aux deux pistes. Vous pourrez retranscrire dans une autre langue."))
                    }
                    Picker("Langue", selection: $model.newSessionLanguage) {
                        ForEach(model.sessionLanguageChoices, id: \.self) { choice in Text(SessionLanguageLabel.title(choice)).tag(choice) }
                    }.labelsHidden().fixedSize()
                }
                if !model.setupMicrophones.devices.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Eyebrow(text: String(localized: "Micro"))
                            HelpButton(text: String(localized: "Le micro enregistré pendant toute la session. Par défaut, le dernier choisi s’il est branché, sinon l’entrée par défaut du Mac. Vous pourrez en changer pendant l’enregistrement."))
                        }
                        MicrophonePicker(devices: model.setupMicrophones.devices, selection: model.setupMicrophone) { model.newSessionMicrophone = $0 }
                    }
                }
                HStack(spacing: 10) {
                    Button(action: start) {
                        Label(model.isStarting ? "Préparation…" : model.isDemoMode ? "Simuler l’enregistrement" : "Démarrer l’enregistrement", systemImage: "record.circle")
                    }.buttonStyle(StudioButtonStyle(primary: true, destructive: true)).disabled(model.isStarting)
                        .keyboardShortcut(.defaultAction)
                    Button("Annuler") { model.library() }.buttonStyle(StudioButtonStyle()).keyboardShortcut(.cancelAction)
                }
            }.frame(maxWidth: 820, alignment: .leading).padding(30).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { nameFocused = true }
    }
    private func start() {
        model.startCapture(kind: model.newSessionKind, title: model.newSessionTitle, language: model.newSessionLanguage, microphone: model.newSessionMicrophone)
    }
    private func kindTile(_ kind: SessionKind) -> some View {
        let selected = model.newSessionKind == kind
        return Button { model.newSessionKind = kind } label: {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol).font(.system(size: Studio.Size.heading)).frame(width: 20)
                Text(kind.label).font(.system(size: Studio.Size.body, weight: selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .foregroundStyle(selected ? Studio.mint : Studio.text)
            .background(selected ? Studio.mint.opacity(0.1) : Studio.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Studio.mint : Studio.line, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    /// What the session will be called if no name is typed.
    static func placeholder(_ kind: SessionKind) -> String {
        let time = Date().formatted(date: .omitted, time: .shortened)
        return kind == .adHoc ? String(localized: "Session du \(time)") : String(localized: "\(kind.label) du \(time)")
    }
}

/// A menu of the inputs present, the selected one ticked.
struct MicrophonePicker: View {
    let devices: [MicrophoneDevice]
    let selection: String?
    var disabled = false
    let choose: (String) -> Void
    var body: some View {
        Picker("Micro", selection: Binding(get: { selection ?? "" }, set: { if !$0.isEmpty { choose($0) } })) {
            if selection == nil { Text("Aucun micro").tag("") }
            ForEach(devices) { device in Label(device.name, systemImage: MicrophonePicker.symbol(device.transport)).tag(device.uid) }
        }.labelsHidden().fixedSize().disabled(disabled)
    }
    static func symbol(_ transport: MicrophoneTransport) -> String {
        switch transport {
        case .builtIn: "laptopcomputer"
        case .bluetooth: "headphones"
        case .usb: "cable.connector"
        case .virtual, .other: "mic"
        }
    }
}

/// How a transcription language choice reads in pickers and transcript headers.
enum SessionLanguageLabel {
    static func title(_ choice: String) -> String {
        choice == SpeechLanguage.automatic ? String(localized: "Détection automatique") : SpeechLanguage.displayName(choice)
    }
    /// The language a transcript was produced in, per track when they differ, marked when detected.
    static func transcript(_ provenance: TranscriptionProvenance) -> String {
        guard let detections = provenance.languageDetection, !detections.isEmpty else { return SpeechLanguage.displayName(provenance.locale) }
        func name(_ detection: LanguageDetection) -> String {
            SpeechLanguage.displayName(detection.locale) + (detection.method == .detected ? String(localized: " (détectée)") : "")
        }
        let languages = Set(detections.map { SpeechLanguage.languageCode(of: $0.locale) })
        if languages.count == 1, let first = detections.first(where: { $0.method == .detected }) ?? detections.first { return name(first) }
        return detections.map { ($0.source == .mic ? String(localized: "Micro : ") : String(localized: "Système : ")) + name($0) }.joined(separator: " · ")
    }
}
