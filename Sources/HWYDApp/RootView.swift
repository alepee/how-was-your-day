import SwiftUI
import HWYDCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            Rectangle().fill(Studio.line).frame(width: 1)
            VStack(spacing: 0) {
                if model.isDemoMode { banner(String(localized: "Mode découverte · exemples fictifs"), color: Studio.mint, button: String(localized: "Quitter")) { model.leaveDemo() } }
                if model.showSettings { SettingsView() }
                else if model.showNewSession { NewSessionView() }
                else if let item = model.selected {
                    if item.id == model.activeCaptureID { CaptureView(recording: item) }
                    else { DetailView(recording: item) }
                } else { LibraryView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomTrailing) { ToastStack() }
        }
        .foregroundStyle(Studio.text).background(Studio.background).preferredColorScheme(model.appearancePreference.colorScheme)
        .frame(minWidth: 860, minHeight: 660)
        .sheet(isPresented: Binding(get: { model.editingSpeakerID != nil }, set: { if !$0 { model.editingSpeakerID = nil } })) { SpeakerEditor() }
        .alert("Supprimer cette session ?", isPresented: Binding(get: { model.deleteCandidate != nil }, set: { if !$0 { model.deleteCandidate = nil } })) {
            Button("Annuler", role: .cancel) { model.deleteCandidate = nil }
            Button("Supprimer", role: .destructive) { model.deleteConfirmed() }
        } message: { Text("Les notes et les versions du transcript seront supprimées de la bibliothèque locale.") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: "waveform").font(.system(size: 20)).foregroundStyle(Studio.mint)
                Text("hwyd").font(.system(size: 24, weight: .semibold)).tracking(-1)
            }.padding(.vertical, 24).padding(.horizontal, 12)
            nav(String(localized: "Toutes les sessions"), symbol: "square.stack", selected: !model.showSettings && !model.showNewSession && model.selectedID == nil) { model.library() }
            // One entry for the capture: it starts a session, then becomes the running one.
            if let active = model.activeCapture {
                nav("\(model.isCapturePaused ? String(localized: "En pause") : String(localized: "En cours")) · \(timeLabel(model.elapsed))", symbol: model.isCapturePaused ? "pause.circle" : "record.circle", selected: !model.showSettings && model.selectedID == active.id) { model.select(active) }
            } else {
                nav(String(localized: "Nouvelle session"), symbol: "record.circle", selected: model.showNewSession && !model.showSettings) { model.requestNewSession() }
            }
            if model.showSettings {
                Eyebrow(text: String(localized: "Réglages")).padding(.top, 26).padding(.horizontal, 12).padding(.bottom, 8)
                ForEach(SettingsCategory.allCases) { category in
                    nav(category.title, symbol: category.symbol, selected: model.settingsCategory == category) { model.settingsCategory = category }
                }
            } else {
            Eyebrow(text: String(localized: "Récentes")).padding(.top, 26).padding(.horizontal, 12).padding(.bottom, 8)
            ForEach(Array(model.recordings.filter { $0.id != model.activeCaptureID }.prefix(5))) { item in
                // A tap gesture rather than a Button: on macOS a plain Button swallows the right click,
                // so its context menu never opens. Same pattern as the library rows.
                HStack(spacing: 9) { Image(systemName: item.kind.symbol).frame(width: 14); Text(item.title).lineLimit(1).truncationMode(.tail); Spacer(minLength: 0) }
                    .font(.system(size: Studio.Size.caption)).foregroundStyle(model.selectedID == item.id ? Studio.mint : Studio.muted)
                    .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(model.selectedID == item.id ? Studio.mint.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { model.select(item) }
                    .contextMenu { SessionContextMenu(item: item) }
                    .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.select(item) }
            }
            }
            Spacer()
            if model.hasUnsavedChanges {
                Button { model.retrySave() } label: { Label("Enregistrer les notes", systemImage: "arrow.clockwise").contentShape(Rectangle()) }.buttonStyle(.plain).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.copper).padding(10)
            }
            nav(String(localized: "Réglages"), symbol: "slider.horizontal.3", selected: model.showSettings) { model.showSettings = true }
            HStack(spacing: 7) { Circle().fill(Studio.mint).frame(width: 5, height: 5); Text("Sur ce Mac").font(.system(size: Studio.Size.caption)); Spacer(); Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev").font(.system(size: Studio.Size.caption, design: .monospaced)) }.foregroundStyle(Studio.muted).padding(12)
        }.padding(.horizontal, 10).padding(.bottom, 8).background(Studio.inset)
    }
    private func nav(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.system(size: Studio.Size.body, weight: selected ? .medium : .regular)).frame(maxWidth: .infinity, alignment: .leading).padding(11).foregroundStyle(selected ? Studio.mint : Studio.text).background(selected ? Studio.mint.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain)
    }
    private func banner(_ text: String, color: Color, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) { Text(text).font(.system(size: Studio.Size.caption)).lineSpacing(3); Spacer(); Button(action: action) { Text(button).padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle()) }.buttonStyle(.plain).font(.system(size: Studio.Size.caption, weight: .semibold)) }.foregroundStyle(color).padding(.horizontal, 23).padding(.vertical, 10).background(color.opacity(0.07))
    }
}
struct MenuContentView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack { Image(systemName: "waveform").foregroundStyle(Studio.mint); Text("How Was Your Day").font(.system(size: Studio.Size.body, weight: .semibold)); Spacer() }
            if let active = model.activeCapture {
                HStack { Circle().fill(model.isCapturePaused ? Studio.muted : Studio.copper).frame(width: 7, height: 7); Text(model.isCapturePaused ? "En pause" : model.isDemoMode ? "Simulation" : "Enregistrement").font(.system(size: Studio.Size.caption)).foregroundStyle(model.isCapturePaused ? Studio.muted : Studio.copper); Spacer(); Text(timeLabel(model.elapsed)).monospacedDigit() }
                Text(active.title).font(.system(size: Studio.Size.heading, weight: .medium))
                Button { model.toggleCapturePause() } label: { Label(model.isCapturePaused ? "Reprendre" : "Pause", systemImage: model.isCapturePaused ? "record.circle" : "pause.fill").frame(maxWidth: .infinity) }.buttonStyle(StudioButtonStyle(primary: model.isCapturePaused))
                Button { model.stopCapture() } label: { Label("Terminer la session", systemImage: "stop.fill").frame(maxWidth: .infinity) }.buttonStyle(StudioButtonStyle(primary: true, destructive: true))
                Button { model.select(active); model.showWindow?() } label: { Label("Ouvrir les notes", systemImage: "macwindow.on.rectangle").frame(maxWidth: .infinity) }.buttonStyle(StudioButtonStyle())
            } else {
                Text("Une conversation à garder ?").font(.system(size: Studio.Size.heading, weight: .medium))
                Picker("Type", selection: $model.newSessionKind) {
                    ForEach(SessionKind.allCases, id: \.self) { kind in Label(kind.label, systemImage: kind.symbol).tag(kind) }
                }.labelsHidden()
                TextField(NewSessionView.placeholder(model.newSessionKind), text: $model.newSessionTitle).textFieldStyle(.roundedBorder)
                    .onSubmit { model.startCapture(kind: model.newSessionKind, title: model.newSessionTitle) }
                Button { model.startCapture(kind: model.newSessionKind, title: model.newSessionTitle) } label: { Label(model.isStarting ? "Préparation…" : model.isDemoMode ? "Simuler l’enregistrement" : "Démarrer l’enregistrement", systemImage: "record.circle").frame(maxWidth: .infinity) }.buttonStyle(StudioButtonStyle(primary: true, destructive: true)).disabled(model.isStarting)
            }
            Divider().overlay(Studio.line)
            Button { model.library(); model.showWindow?() } label: { Label("Ouvrir les sessions", systemImage: "rectangle.on.rectangle").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle()) }.buttonStyle(.plain).font(.system(size: Studio.Size.body))
            Button { model.showWindow?(); model.showSettings = true } label: { Label("Réglages", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle()) }.buttonStyle(.plain).font(.system(size: Studio.Size.body))
            HStack { Spacer(); Button("Quitter") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted) }
        }.padding(23).frame(width: 340).foregroundStyle(Studio.text).background(Studio.background).preferredColorScheme(model.appearancePreference.colorScheme)
    }
}
