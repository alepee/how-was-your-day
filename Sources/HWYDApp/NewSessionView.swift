import SwiftUI
import HWYDCore

/// Set up a session before recording: its name, kind, microphone and language. Nothing is captured
/// until the user presses the start button. When the kind records other people, that button works in
/// two steps: it first declares them informed and agreeing, which stamps the card, then it starts.
struct NewSessionView: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var nameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The stamp's tilt, drawn again at each declaration so no two look alike.
    @State private var stampAngle = -10.0
    private var stampDate: Date? { model.newSessionKind.involvesOthers ? model.newSessionConsentAt : nil }
    /// A card centred in the pane, holding its own actions, so a large window frames it
    /// instead of stretching it.
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                card.frame(maxWidth: 720).padding(.horizontal, 48).padding(.vertical, 56)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .onAppear { nameFocused = true }
        .onChange(of: model.newSessionConsentAt) { _, date in
            guard date != nil else { return }
            stampAngle = -Double.random(in: 5...16)
            if !reduceMotion { StampImpact.feel() }
        }
    }
    private var card: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                Eyebrow(text: String(localized: "Nouvelle session"))
                header
                FlowRow(spacing: 8) { ForEach(SessionKind.allCases, id: \.self) { kind in kindChip(kind) } }
                HStack(spacing: 10) {
                    if !model.setupMicrophones.devices.isEmpty { microphoneMenu }
                    languageMenu
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 36).padding(.top, 32).padding(.bottom, 30)
            actions
        }
        .background(Studio.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Studio.line))
        // The stamp lands across the card's corner, over the title.
        .overlay(alignment: .topTrailing) {
            ZStack {
                if let date = stampDate {
                    ConsentStamp(date: date).rotationEffect(.degrees(stampAngle))
                        .transition(.stamp(reduceMotion: reduceMotion))
                }
            }
            .frame(width: 140, height: 140).offset(x: 34, y: -26).allowsHitTesting(false)
            .animation(.spring(response: 0.34, dampingFraction: 0.55), value: stampDate)
        }
    }
    /// The name, as the card's title.
    private var header: some View {
        TextField("Nom", text: $model.newSessionTitle, prompt: Text(NewSessionView.placeholder(model.newSessionKind)).foregroundStyle(Studio.muted))
            .textFieldStyle(.plain).font(.system(size: Studio.Size.title, weight: .semibold)).tracking(-0.7)
            .focused($nameFocused).onSubmit { model.advanceNewSession() }
            .help(String(localized: "Facultatif. Sans nom, la session s’appelle d’après son type et l’heure de début. Vous pourrez le changer ensuite."))
            .padding(.trailing, 96).padding(.bottom, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Studio.line).frame(height: 1) }
    }
    private func kindChip(_ kind: SessionKind) -> some View {
        let selected = model.newSessionKind == kind
        return Button { model.newSessionKind = kind } label: {
            HStack(spacing: 7) {
                Image(systemName: kind.symbol)
                Text(kind.label)
            }
                .font(.system(size: Studio.Size.body, weight: selected ? .semibold : .regular)).fixedSize()
                .padding(.horizontal, 13).padding(.vertical, 8)
                .foregroundStyle(selected ? Studio.mint : Studio.text)
                .background(selected ? Studio.mint.opacity(0.1) : Studio.background, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(selected ? Studio.mint : Studio.line, lineWidth: selected ? 1.5 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var microphoneMenu: some View {
        let devices = model.setupMicrophones.devices, selected = model.setupMicrophones.device(model.setupMicrophone)
        return Menu {
            ForEach(devices) { device in
                Button { model.newSessionMicrophone = device.uid } label: {
                    if device.uid == selected?.uid { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                }
            }
        } label: {
            SetupPill(symbol: selected.map { MicrophonePicker.symbol($0.transport) } ?? "mic", title: selected?.name ?? String(localized: "Aucun micro"))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(String(localized: "Le micro enregistré pendant toute la session. Par défaut, le dernier choisi s’il est branché, sinon l’entrée par défaut du Mac. Vous pourrez en changer pendant l’enregistrement."))
        .accessibilityLabel("Micro")
    }
    private var languageMenu: some View {
        Menu {
            ForEach(model.sessionLanguageChoices, id: \.self) { choice in
                Button { model.newSessionLanguage = choice } label: {
                    if choice == model.newSessionLanguage { Label(SessionLanguageLabel.title(choice), systemImage: "checkmark") } else { Text(SessionLanguageLabel.title(choice)) }
                }
            }
        } label: {
            SetupPill(symbol: "globe", title: SessionLanguageLabel.title(model.newSessionLanguage))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(String(localized: "En détection automatique, HWYD choisit la langue de chaque piste parmi les langues installées, d’après le début de l’enregistrement. Choisissez une langue pour l’imposer aux deux pistes. Vous pourrez retranscrire dans une autre langue."))
        .accessibilityLabel("Langue")
    }
    /// Cancel, then the start button: with other people, it declares before it starts.
    private var actions: some View {
        HStack(spacing: 18) {
            Button("Annuler") { model.library() }.buttonStyle(StudioButtonStyle()).keyboardShortcut(.cancelAction)
            Spacer(minLength: 8)
            Button { model.advanceNewSession() } label: { NewSessionView.startLabel(model) }
            .buttonStyle(StudioButtonStyle(primary: true, destructive: !model.newSessionNeedsConsent)).disabled(model.isStarting)
            .keyboardShortcut(.defaultAction)
            .help(model.newSessionNeedsConsent ? NewSessionView.consentHelp : "")
        }
        .padding(.horizontal, 24).padding(.vertical, 15).background(Studio.inset)
        .overlay(alignment: .top) { Rectangle().fill(Studio.line).frame(height: 1) }
    }
    /// The start button's label: the declaration while one is needed, then the start.
    static func startLabel(_ model: AppModel) -> some View {
        if model.newSessionNeedsConsent { return Label("Consentement recueilli", systemImage: "checkmark.seal") }
        return Label(model.isStarting ? "Préparation…" : model.isDemoMode ? "Simuler l’enregistrement" : "Démarrer l’enregistrement", systemImage: "record.circle")
    }
    static var consentHelp: String {
        String(localized: "Informez chaque personne présente et obtenez son accord, puis déclarez-le ici avant de démarrer. Votre déclaration et son heure sont consignées dans la session et ses exports. Elle ne vaut pas consentement à mémoriser une voix.")
    }
    /// What the session will be called if no name is typed.
    static func placeholder(_ kind: SessionKind) -> String {
        let time = Date().formatted(date: .omitted, time: .shortened)
        return String(localized: "\(kind.label) du \(time)")
    }
}

/// A setup choice shown as a quiet pill that opens its menu.
private struct SetupPill: View {
    let symbol: String
    let title: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(Studio.muted)
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Studio.muted)
        }
        .font(.system(size: Studio.Size.body)).foregroundStyle(Studio.text)
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Studio.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Studio.line))
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// Lays its children out in rows, wrapping when the width runs out.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }
    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }
    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index); rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
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
