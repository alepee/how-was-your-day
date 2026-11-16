import Foundation

/// One part of a summary the user can keep or leave out of an export.
public enum SummarySection: String, CaseIterable, Hashable, Sendable {
    case overview, keyPoints, decisions, actions, details, context

    /// Level-2 heading of the section in a French summary. Key points are level-3 headings under the overview.
    public var heading: String? { heading(in: .french) }
    /// Level-2 heading of the section in a summary written in `language`.
    public func heading(in language: SummaryLanguage) -> String? { SummaryVocabulary(language).heading(self) }

    /// Recognizes a heading in any summary language: a summary keeps its language when the user changes theirs.
    init?(heading: String) {
        guard let section = Self.allCases.first(where: { section in SummaryLanguage.allCases.contains { section.heading(in: $0) == heading } }) else { return nil }
        self = section
    }

    /// Sections ticked when the export sheet opens. The agent's context notes come from the user's own sources,
    /// not from the session, and can carry private information unrelated to it: they are left out unless asked for.
    public static let exportDefault: Set<SummarySection> = Set(allCases).subtracting([.context])
}

/// The summary of one session as a standalone document: title, date, participants, then the summary.
/// The header is always exported; the user chooses the sections of the summary, and the overview always stays.
/// Exported text is in the language the summary was written in (see docs/localization.md).
public enum SummaryExport {
    /// Markdown document, or nil when the session has no summary.
    public static func markdown(_ item: Recording, sections: Set<SummarySection> = SummarySection.exportDefault) -> String? {
        guard let summary = item.summary.map({ keeping(sections, of: $0) })?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return nil }
        let words = vocabulary(item)
        var header = "# " + item.title + "\n\n" + metadata(item)
        if let provenance = item.summaryProvenance {
            header += "\n\n_" + words.generated(by: provenance.model, on: words.date(provenance.generatedAt), review: true) + "_"
        } else {
            header += "\n\n_" + words.generatedByModel + "_"
        }
        if item.summaryIsStale { header += "\n\n_" + words.staleNotice + "_" }
        return header + "\n\n" + summary + "\n"
    }

    /// Words of the session's summary document, in the summary's own language.
    public static func vocabulary(_ item: Recording) -> SummaryVocabulary { SummaryVocabulary(item.summaryProvenance?.summaryLanguage ?? .french) }

    /// The sections present in the session's summary, in reading order.
    public static func sections(_ item: Recording) -> [SummarySection] {
        guard let markdown = item.summary else { return [] }
        var found = Set<SummarySection>(), current: SummarySection?
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if let title = level2Title(line) { current = SummarySection(heading: title); if let current { found.insert(current) } }
            else if current == .overview, line.hasPrefix("### ") { found.insert(.keyPoints) }
        }
        return SummarySection.allCases.filter(found.contains)
    }

    /// The summary Markdown with only the chosen sections. The overview is always kept, and so is any
    /// level-2 section this export does not know. Key points are the level-3 parts of the overview.
    public static func keeping(_ sections: Set<SummarySection>, of markdown: String) -> String {
        let sections = sections.union([.overview])
        var kept: [Substring] = [], current: SummarySection?, skipping = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if let title = level2Title(line) {
                current = SummarySection(heading: title)
                skipping = current.map { !sections.contains($0) } ?? false
            } else if current == .overview, line.hasPrefix("### ") {
                skipping = !sections.contains(.keyPoints)
            }
            if !skipping { kept.append(line) }
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func level2Title(_ line: Substring) -> String? {
        line.hasPrefix("## ") ? line.dropFirst(3).trimmingCharacters(in: .whitespaces) : nil
    }

    /// File name without extension, safe for the Finder.
    public static func fileName(_ item: Recording) -> String {
        let title = item.title.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\r\t")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? "Session" : title) + vocabulary(item).fileSuffix
    }

    static func metadata(_ item: Recording) -> String {
        let words = vocabulary(item)
        var parts = [words.date(item.startedAt), "\(max(1, Int(item.duration / 60))) min"]
        let names = item.participants.map(\.label)
        if !names.isEmpty { parts.append(words.participants + names.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}
