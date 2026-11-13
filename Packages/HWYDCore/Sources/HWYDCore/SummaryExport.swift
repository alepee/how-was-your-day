import Foundation

/// The summary of one session as a standalone document: title, date, participants, then the summary.
/// Exported text stays in French, like the summary itself (see docs/localization.md).
/// Exports leave out the agent's context notes: they come from the user's own sources, not from the session,
/// and can carry private information unrelated to it.
public enum SummaryExport {
    /// Markdown document, or nil when the session has no summary.
    public static func markdown(_ item: Recording) -> String? {
        guard let summary = item.summary.map(withoutContext)?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return nil }
        var header = "# " + item.title + "\n\n" + metadata(item)
        if let provenance = item.summaryProvenance {
            header += "\n\n_Synthèse générée par " + provenance.model + " le " + date(provenance.generatedAt) + ", à relire._" // l10n:ignore
        } else {
            header += "\n\n_Synthèse générée par un modèle, à relire._" // l10n:ignore
        }
        return header + "\n\n" + summary + "\n"
    }

    /// The summary Markdown without its "## Contexte" section, up to the next level-2 heading.
    public static func withoutContext(_ markdown: String) -> String {
        var kept: [Substring] = [], skipping = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") { skipping = line.trimmingCharacters(in: .whitespaces) == "## Contexte" } // l10n:ignore
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// File name without extension, safe for the Finder.
    public static func fileName(_ item: Recording) -> String {
        let title = item.title.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? "Session" : title) + " - synthèse" // l10n:ignore
    }

    static func metadata(_ item: Recording) -> String {
        var parts = [date(item.startedAt), "\(max(1, Int(item.duration / 60))) min"]
        let names = item.participants.map(\.label)
        if !names.isEmpty { parts.append("Participants : " + names.joined(separator: ", ")) } // l10n:ignore
        return parts.joined(separator: " · ")
    }
    static func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(Locale(identifier: "fr_FR")))
    }
}
