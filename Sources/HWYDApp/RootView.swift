import SwiftUI
import HWYDCore

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 190)
            Rectangle().fill(Studio.line).frame(width: 1)
            VStack(spacing: 0) {
                if model.isDemoMode { banner("Mode découverte · exemples fictifs", color: Studio.mint, button: "Quitter") { model.leaveDemo() } }
                if let error = model.errorMessage { banner(error, color: Studio.copper, button: "Fermer") { model.errorMessage = nil } }
                if let notice = model.notice { banner(notice, color: Studio.mint, button: "OK") { model.notice = nil } }
                if model.showSettings { SettingsView() }
                else if let item = model.selected {
                    if item.id == model.activeCaptureID { CaptureView(recording: item) }
                    else { DetailView(recording: item) }
                } else { LibraryView() }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
            nav("Toutes les sessions", symbol: "square.stack", selected: !model.showSettings && model.selectedID == nil) { model.library() }
            nav("Nouvelle session", symbol: "plus.circle", selected: false) { model.startCapture() }
            if let active = model.activeCapture {
                nav("En cours · \(timeLabel(model.elapsed))", symbol: "record.circle", selected: !model.showSettings && model.selectedID == active.id) { model.select(active) }
            }
            if model.showSettings {
                Eyebrow(text: "Réglages").padding(.top, 26).padding(.horizontal, 12).padding(.bottom, 8)
                ForEach(SettingsCategory.allCases) { category in
                    nav(category.rawValue, symbol: category.symbol, selected: model.settingsCategory == category) { model.settingsCategory = category }
                }
            } else {
            Eyebrow(text: "Récentes").padding(.top, 26).padding(.horizontal, 12).padding(.bottom, 8)
            ForEach(Array(model.recordings.prefix(5))) { item in
                Button { model.select(item) } label: {
                    HStack(spacing: 9) { Image(systemName: item.kind.symbol).frame(width: 14); Text(item.title).lineLimit(2); Spacer(minLength: 0) }
                        .font(.system(size: 11)).foregroundStyle(model.selectedID == item.id ? Studio.mint : Studio.muted)
                        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(model.selectedID == item.id ? Studio.mint.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            }
            }
            Spacer()
            if model.hasUnsavedChanges {
                Button { model.retrySave() } label: { Label("Enregistrer les notes", systemImage: "arrow.clockwise") }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Studio.copper).padding(10)
            }
            nav("Réglages", symbol: "slider.horizontal.3", selected: model.showSettings) { model.showSettings = true }
            HStack(spacing: 7) { Circle().fill(Studio.mint).frame(width: 5, height: 5); Text("Sur ce Mac").font(.system(size: 10)); Spacer(); Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev").font(.system(size: 10, design: .monospaced)) }.foregroundStyle(Studio.muted).padding(12)
        }.padding(.horizontal, 10).padding(.bottom, 8).background(Studio.inset)
    }
    private func nav(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol).font(.system(size: 12, weight: selected ? .medium : .regular)).frame(maxWidth: .infinity, alignment: .leading).padding(11).foregroundStyle(selected ? Studio.mint : Studio.text).background(selected ? Studio.mint.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6)) }.buttonStyle(.plain)
    }
    private func banner(_ text: String, color: Color, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) { Text(text).font(.system(size: 11)).lineSpacing(3); Spacer(); Button(button, action: action).buttonStyle(.plain).font(.system(size: 11, weight: .semibold)) }.foregroundStyle(color).padding(.horizontal, 23).padding(.vertical, 10).background(color.opacity(0.07))
    }
}
struct MenuContentView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack { Image(systemName: "waveform").foregroundStyle(Studio.mint); Text("How Was Your Day").font(.system(size: 14, weight: .semibold)); Spacer(); Image(systemName: "lock").foregroundStyle(Studio.muted) }
            if let active = model.activeCapture {
                HStack { Circle().fill(Studio.copper).frame(width: 7, height: 7); Text(model.isDemoMode ? "Simulation" : "Enregistrement").font(.system(size: 11)).foregroundStyle(Studio.copper); Spacer(); Text(timeLabel(model.elapsed)).monospacedDigit() }
                Text(active.title).font(.system(size: 17, weight: .medium))
                Button { model.stopCapture() } label: { Label("Terminer la session", systemImage: "stop.fill").frame(maxWidth: .infinity) }.buttonStyle(StudioButtonStyle(primary: true, destructive: true))
                Button("Ouvrir les notes") { model.select(active); model.showWindow?() }.buttonStyle(StudioButtonStyle())
            } else {
                Text("Une conversation à garder ?").font(.system(size: 19, weight: .medium))
                Text("Réunion, appel ou pensée du moment.").font(.system(size: 12)).foregroundStyle(Studio.muted)
                Button { model.startCapture() } label: { Label(model.isStarting ? "Préparation…" : model.isDemoMode ? "Simuler une session" : "Commencer une session", systemImage: "record.circle.fill").frame(maxWidth: .infinity) }.buttonStyle(StudioButtonStyle(primary: true)).disabled(model.isStarting)
            }
            Divider().overlay(Studio.line)
            Button { model.library(); model.showWindow?() } label: { Label("Ouvrir les sessions", systemImage: "rectangle.on.rectangle").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).font(.system(size: 12))
            Button { model.showWindow?(); model.showSettings = true } label: { Label("Réglages", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).font(.system(size: 12))
            HStack { Text(model.isDemoMode ? "Exemples fictifs" : "Sur ce Mac").font(.system(size: 10)).foregroundStyle(Studio.muted); Spacer(); Button("Quitter") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Studio.muted) }
        }.padding(23).frame(width: 340).foregroundStyle(Studio.text).background(Studio.background).preferredColorScheme(model.appearancePreference.colorScheme)
    }
}
