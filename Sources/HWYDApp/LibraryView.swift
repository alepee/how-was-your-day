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
                        Text("Vos sessions").font(.system(size: 29, weight: .semibold)).tracking(-0.7)
                        Text("Des conversations, des idées, une trace.").font(.system(size: 13)).foregroundStyle(Studio.muted)
                    }
                    Spacer()
                    Button { model.startCapture() } label: { Label(model.isStarting ? "Préparation…" : "Enregistrer", systemImage: "record.circle.fill") }
                        .buttonStyle(StudioButtonStyle(primary: true)).disabled(model.isStarting)
                }
                HStack(spacing: 18) {
                    Image(systemName: "waveform").font(.system(size: 26, weight: .light)).foregroundStyle(Studio.mint)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(model.isDemoMode ? "EXPLORER STUDIO" : "VOTRE ESPACE LOCAL").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(Studio.mint)
                        Text(model.isDemoMode ? "Exemples fictifs. Aucun micro n’est utilisé." : "Audio, notes et conversations restent sur ce Mac.").font(.system(size: 12)).foregroundStyle(Studio.muted)
                    }
                    Spacer()
                    Image(systemName: "lock.shield").font(.system(size: 21, weight: .light)).foregroundStyle(Studio.muted)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Studio.surface, in: RoundedRectangle(cornerRadius: 9))
                if !model.isDemoMode { UpcomingMeetingsView(calendar: model.calendar) }
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Studio.muted)
                        TextField("Rechercher une session, une phrase…", text: $model.search).textFieldStyle(.plain).font(.system(size: 12))
                        if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Studio.muted) }
                    }.padding(10).background(Studio.inset, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Studio.line))
                    Menu {
                        Button("Tous les types") { model.kindFilter = nil }
                        ForEach(SessionKind.allCases, id: \.self) { kind in Button(kind.label) { model.kindFilter = kind } }
                    } label: { Label(model.kindFilter?.label ?? "Tous les types", systemImage: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).fixedSize()
                }
                if model.isLoading { ProgressView().frame(maxWidth: .infinity).padding(50) }
                else if model.recordings.isEmpty {
                    VStack(spacing: 0) {
                        EmptyPanel(symbol: "waveform.path", title: "La prochaine conversation commence ici.", detail: "Enregistrez une réunion, un appel ou une idée. Prenez vos notes pendant que la conversation suit son cours.")
                        Button("Explorer avec des exemples") { model.enterDemo() }.buttonStyle(StudioButtonStyle()).padding(.bottom, 35)
                    }
                } else if model.filteredRecordings.isEmpty {
                    EmptyPanel(symbol: "magnifyingglass", title: "Aucune session trouvée", detail: "Essayez un autre mot ou retirez le filtre de type.")
                } else {
                    if !model.todayRecordings.isEmpty { section("Aujourd’hui", items: model.todayRecordings) }
                    if !model.olderRecordings.isEmpty { section("Précédemment", items: model.olderRecordings) }
                }
                Text("Les notes et transcripts sont conservés. La rétention audio sera appliquée une fois le pipeline intégré.").font(.system(size: 11)).foregroundStyle(Studio.muted).lineSpacing(4)
            }.padding(32).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Studio.background)
    }
    private func section(_ title: String, items: [Recording]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Eyebrow(text: title); Spacer(); Text("\(items.count) session\(items.count > 1 ? "s" : "")").font(.system(size: 10)).foregroundStyle(Studio.muted) }.padding(.bottom, 3)
            ForEach(items) { item in SessionRow(recording: item).onTapGesture { model.select(item) }.contextMenu {
                Button("Ouvrir") { model.select(item) }
                if item.id != model.activeCaptureID { Button("Supprimer…", role: .destructive) { model.deleteCandidate = item } }
            } }
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
                Text(recording.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(recording.kind.label + (recording.participantNames.isEmpty ? "" : " · " + recording.participantNames))
                    .font(.system(size: 11)).foregroundStyle(Studio.muted).lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 7) {
                Text(recording.startedAt.formatted(date: .omitted, time: .shortened)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Studio.mint)
                Text(recording.state == .recording ? "En cours" : recording.state == .interrupted ? "Interrompue" : "\(max(1, Int(recording.duration / 60))) min")
                    .font(.system(size: 10)).foregroundStyle(recording.state == .recording ? Studio.copper : Studio.muted)
            }
        }.padding(15).background(Studio.surface.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Studio.line))
            .contentShape(RoundedRectangle(cornerRadius: 8)).accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
    }
}
