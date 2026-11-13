import SwiftUI
import HWYDCore

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        Eyebrow(text: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        Text("Vos sessions").font(.system(size: Studio.Size.title, weight: .semibold)).tracking(-0.7)
                    }
                    Spacer()
                    Button { model.requestNewSession() } label: { Label(model.isDemoMode ? "Simuler une session" : "Nouvelle session", systemImage: "record.circle") }
                        .buttonStyle(StudioButtonStyle(primary: true)).disabled(model.isStarting)
                }
                if !model.isDemoMode { UpcomingMeetingsView(calendar: model.calendar) }
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Studio.muted)
                        TextField("Rechercher une session, une phrase…", text: $model.search).textFieldStyle(.plain).font(.system(size: Studio.Size.body))
                        if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 20, height: 20).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(Studio.muted) }
                    }.padding(10).background(Studio.inset, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Studio.line))
                    Menu {
                        Button("Tous les types") { model.kindFilter = nil }
                        ForEach(SessionKind.allCases, id: \.self) { kind in Button(kind.label) { model.kindFilter = kind } }
                    } label: { Label(model.kindFilter?.label ?? String(localized: "Tous les types"), systemImage: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).fixedSize()
                }
                if model.isLoading { ProgressView().frame(maxWidth: .infinity).padding(50) }
                else if model.recordings.isEmpty {
                    VStack(spacing: 0) {
                        EmptyPanel(symbol: "waveform.path", title: String(localized: "La prochaine conversation commence ici."), detail: String(localized: "Enregistrez une réunion, un appel ou une idée. Prenez vos notes pendant que la conversation suit son cours."))
                        Button("Explorer avec des exemples") { model.enterDemo() }.buttonStyle(StudioButtonStyle()).padding(.bottom, 35)
                    }
                } else {
                    // Filter once per render: the search scans every transcript.
                    let items = model.filteredRecordings
                    let today = items.filter { Calendar.current.isDateInToday($0.startedAt) }
                    let older = items.filter { !Calendar.current.isDateInToday($0.startedAt) }
                    if items.isEmpty {
                        EmptyPanel(symbol: "magnifyingglass", title: String(localized: "Aucune session trouvée"), detail: String(localized: "Essayez un autre mot ou retirez le filtre de type."))
                    } else {
                        if !today.isEmpty { section(String(localized: "Aujourd’hui"), items: today) }
                        if !older.isEmpty { section(String(localized: "Précédemment"), items: older) }
                    }
                }
            }.padding(32).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Studio.background)
    }
    private func section(_ title: String, items: [Recording]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Eyebrow(text: title); Spacer(); Text("\(items.count) session(s)").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted) }.padding(.bottom, 3)
            ForEach(items) { item in SessionRow(recording: item).onTapGesture { model.select(item) }.contextMenu { SessionContextMenu(item: item) } }
        }
    }
}
/// Right-click actions on a session, shared by the library and the sidebar.
struct SessionContextMenu: View {
    @EnvironmentObject var model: AppModel
    let item: Recording
    var body: some View {
        Button("Ouvrir") { model.select(item) }
        if !item.isDemo, item.id != model.activeCaptureID {
            if model.summaryID == item.id {
                Button("Annuler la synthèse") { model.cancelSummary() }
            } else {
                Button(item.summary == nil ? "Générer une synthèse" : "Régénérer la synthèse") { model.generateSummary(item.id) }
                    .disabled(!model.canGenerateSummary(item))
            }
        }
        if item.id != model.activeCaptureID {
            Divider()
            Button("Supprimer…", role: .destructive) { model.deleteCandidate = item }
                .disabled(item.id == model.processingID || item.id == model.summaryID)
        }
    }
}
struct SessionRow: View {
    let recording: Recording
    var body: some View {
        HStack(spacing: 15) {
            Image(systemName: recording.kind.symbol).font(.system(size: 18, weight: .light)).foregroundStyle(Studio.mint)
                .frame(width: 40, height: 42).background(Studio.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 7) {
                Text(recording.title).font(.system(size: Studio.Size.body, weight: .semibold)).lineLimit(1)
                Text(recording.kind.label + (recording.participantNames.isEmpty ? "" : " · " + recording.participantNames))
                    .font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 7) {
                Text(recording.startedAt.formatted(date: .omitted, time: .shortened)).font(.system(size: Studio.Size.caption, design: .monospaced)).foregroundStyle(Studio.mint)
                Text(recording.state == .recording ? "En cours" : recording.state == .interrupted ? "Interrompue" : "\(max(1, Int(recording.duration / 60))) min")
                    .font(.system(size: Studio.Size.caption)).foregroundStyle(recording.state == .recording ? Studio.copper : Studio.muted)
            }
        }.padding(15).background(Studio.surface.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Studio.line))
            .contentShape(RoundedRectangle(cornerRadius: 8)).accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
    }
}
