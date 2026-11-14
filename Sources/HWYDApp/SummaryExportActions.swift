import AppKit
import HWYDCore
import UniformTypeIdentifiers

enum SummaryExportFormat { case pdf, markdown }

extension AppModel {
    /// Saves the selected session's summary as a standalone PDF or Markdown file chosen by the user.
    func exportSummary(_ format: SummaryExportFormat) {
        guard let item = selected, item.summary != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .pdf ? .pdf : UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = SummaryExport.fileName(item)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch format {
            case .markdown:
                guard let text = SummaryExport.markdown(item) else { return }
                try Data(text.utf8).write(to: url, options: .atomic)
            case .pdf:
                try SummaryPDF.write(item, to: url)
            }
            notifier.notify(.success(String(localized: "Synthèse exportée."),
                                     actions: [.perform(String(localized: "Afficher dans le Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }]))
        } catch {
            notifier.notify(.error(String(localized: "Export de la synthèse impossible : \(error.localizedDescription)")))
        }
    }
}
