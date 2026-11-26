import SwiftUI
import HWYDCore

/// Chooses the sections of the summary to export, before the save panel. The header and the overview are always exported.
/// Nothing is remembered: each export starts from `SummarySection.exportDefault`, so context notes are never shared by habit.
struct SummaryExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let recording: Recording
    let format: SummaryExportFormat
    let onExport: (Set<SummarySection>) -> Void
    @State private var chosen = SummarySection.exportDefault

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Exporter la synthèse").font(.system(size: Studio.Size.heading, weight: .semibold))
            Text(format == .pdf ? "Choisissez les sections du PDF. Le titre, la date et les participants sont toujours inclus." : "Choisissez les sections du fichier Markdown. Le titre, la date et les participants sont toujours inclus.")
                .font(.system(size: Studio.Size.body)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            if recording.summaryProvenance?.usedNotes == true {
                // The writer had the session notes in mind: a private point noted there may show through.
                Label("Vos notes de session ont servi à rédiger cette synthèse. Vérifiez qu’elle ne reprend pas un point que vous souhaitiez garder privé.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.copper).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SummaryExport.sections(recording), id: \.self) { section in
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle(Self.label(section), isOn: Binding(get: { section == .overview || chosen.contains(section) },
                                                                  set: { if $0 { chosen.insert(section) } else { chosen.remove(section) } }))
                            .disabled(section == .overview)
                        if section == .context {
                            Text("Notes tirées de vos propres sources par l’agent, pas de la session. Elles peuvent contenir des informations privées.")
                                .font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).padding(.leading, 20).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }.toggleStyle(.checkbox).font(.system(size: Studio.Size.body))
            HStack {
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Exporter…") { onExport(chosen.union([.overview])) }
                    .buttonStyle(StudioButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 440).background(Studio.background).foregroundStyle(Studio.text)
    }

    static func label(_ section: SummarySection) -> String {
        switch section {
        case .overview: String(localized: "Résumé")
        case .keyPoints: String(localized: "Points clés")
        case .decisions: String(localized: "Décisions")
        case .actions: String(localized: "Étapes suivantes")
        case .details: String(localized: "Détails")
        case .context: String(localized: "Contexte")
        }
    }
}
