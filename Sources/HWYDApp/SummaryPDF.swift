import AppKit
import HWYDCore
import SwiftUI

/// The summary tab laid out on A4 pages: same components (decision callouts, action rows, topic cards),
/// every topic expanded, source references kept as transcript times. Vector text, light palette only.
/// Text stays in French, like the summary and the Markdown export (see docs/localization.md).
@MainActor enum SummaryPDF {
    static let page = CGSize(width: 595.28, height: 841.89)
    static let margin = (top: CGFloat(54), side: CGFloat(56), bottom: CGFloat(64))
    static var contentWidth: CGFloat { page.width - 2 * margin.side }
    static var contentHeight: CGFloat { page.height - margin.top - margin.bottom }

    /// Fixed light colors: the app palette adapts to the system appearance, paper does not.
    enum Ink {
        static let text = Color(red: 0x20 / 255, green: 0x2b / 255, blue: 0x29 / 255)
        static let muted = Color(red: 0x59 / 255, green: 0x6b / 255, blue: 0x65 / 255)
        static let line = Color(red: 0xcb / 255, green: 0xd5 / 255, blue: 0xd0 / 255)
        static let mint = Color(red: 0x25 / 255, green: 0x69 / 255, blue: 0x51 / 255)
        static let copper = Color(red: 0x99 / 255, green: 0x49 / 255, blue: 0x2f / 255)
        static let tint = Color(red: 0xf1 / 255, green: 0xf5 / 255, blue: 0xf3 / 255)
    }
    enum Size {
        static let small: CGFloat = 8.5, body: CGFloat = 10.5, lead: CGFloat = 12, heading: CGFloat = 13, title: CGFloat = 22
    }

    /// One unbreakable piece of the flow. `keepWithNext` holds a section heading on the page of its first item.
    struct Block {
        var view: AnyView
        var gap: CGFloat
        var keepWithNext = false
        /// Used instead of this block when it is taller than a page.
        var split: [Block]? = nil
        /// Same height as `view`, drawn instead when the block opens a page (no leading separator).
        var atPageTop: AnyView? = nil
        init<V: View>(_ gap: CGFloat, keepWithNext: Bool = false, split: [Block]? = nil, @ViewBuilder _ content: () -> V) {
            view = AnyView(content()); self.gap = gap; self.keepWithNext = keepWithNext; self.split = split
        }
    }

    static func write(_ item: Recording, to url: URL) throws {
        let pages = paginate(blocks(item))
        var box = CGRect(origin: .zero, size: page)
        guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: item.title, kCGPDFContextCreator as String: "How Was Your Day"] as CFDictionary) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for (index, blocks) in pages.enumerated() {
            let renderer = ImageRenderer(content: pageView(blocks, title: item.title, number: index + 1, count: pages.count))
            renderer.proposedSize = ProposedViewSize(page)
            renderer.render { _, draw in
                context.beginPDFPage(nil); draw(context); context.endPDFPage()
            }
        }
        context.closePDF()
    }

    // MARK: Pagination

    static func height(_ block: Block) -> CGFloat {
        let renderer = ImageRenderer(content: block.view.frame(width: contentWidth, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)
        var height: CGFloat = 0
        renderer.render { size, _ in height = size.height }
        return height
    }

    static func paginate(_ input: [Block]) -> [[(block: Block, gap: CGFloat)]] {
        var flow: [(Block, CGFloat)] = []
        for block in input {
            let h = height(block)
            if h > contentHeight, let parts = block.split { flow += parts.map { ($0, height($0)) } } else { flow.append((block, h)) }
        }
        var pages: [[(block: Block, gap: CGFloat)]] = [[]]
        var y: CGFloat = 0
        for (index, (block, h)) in flow.enumerated() {
            var need = (y == 0 ? 0 : block.gap) + h
            if block.keepWithNext, index + 1 < flow.count { need += flow[index + 1].0.gap + flow[index + 1].1 }
            if y > 0, y + need > contentHeight { pages.append([]); y = 0 }
            let gap = y == 0 ? 0 : block.gap
            pages[pages.count - 1].append((block, gap))
            y += gap + h
        }
        return pages
    }

    static func pageView(_ blocks: [(block: Block, gap: CGFloat)], title: String, number: Int, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, entry in
                    (index == 0 ? entry.block.atPageTop ?? entry.block.view : entry.block.view).frame(width: contentWidth, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, entry.gap)
                }
            }.frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                Text(verbatim: "\(number) / \(count)")
            }.font(.system(size: Size.small)).foregroundStyle(Ink.muted)
            .frame(width: contentWidth).padding(.top, 24)
            .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 0.5).padding(.top, 12) }
        }
        .padding(.top, margin.top).padding(.horizontal, margin.side)
        .frame(width: page.width, height: page.height, alignment: .top)
        .background(Color.white)
        .foregroundStyle(Ink.text)
        .environment(\.colorScheme, .light)
    }

    // MARK: Content

    static func blocks(_ item: Recording) -> [Block] {
        var blocks = [header(item)]
        let segments = { (ids: [UUID]) -> [TranscriptSegment] in
            let wanted = Set(ids)
            return item.segments.filter { wanted.contains($0.id) }.sorted { $0.start < $1.start }
        }
        guard let summary = item.summaryProvenance?.structured, summary.details != nil else {
            return blocks + legacy(SummaryExport.withoutContext(item.summary ?? ""))
        }
        // Context notes come from the agent's own sources (the user's vault), not from the session:
        // they can be private and stay out of a document meant to be shared.
        let details = summary.details ?? []
        blocks.append(Block(20) {
            Text(summary.overview).font(.system(size: Size.lead)).lineSpacing(4)
        })
        let stats = [(summary.decisions.count, "décision", "décisions"), (summary.action_items.count, "action", "actions"), // l10n:ignore
                     (details.count, "thème", "thèmes")].filter { $0.0 > 0 } // l10n:ignore
        if !stats.isEmpty {
            blocks.append(Block(12) {
                HStack(spacing: 6) { ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in Chip(count: stat.0, label: stat.0 == 1 ? stat.1 : stat.2) } }
            })
        }
        let points = summary.key_points ?? []
        for row in stride(from: 0, to: points.count, by: 2) {
            blocks.append(Block(row == 0 ? 14 : 6) {
                HStack(alignment: .top, spacing: 6) {
                    KeyPoint(topic: points[row])
                    if row + 1 < points.count { KeyPoint(topic: points[row + 1]) } else { Color.clear.frame(maxWidth: .infinity) }
                }.fixedSize(horizontal: false, vertical: true)
            })
        }
        if !summary.decisions.isEmpty {
            blocks.append(Block(24, keepWithNext: true) { SectionTitle(title: "Décisions", count: summary.decisions.count) }) // l10n:ignore
            for decision in summary.decisions {
                blocks.append(Block(6) { Callout(text: decision.text, segments: segments(decision.evidence_segment_ids)) })
            }
        }
        if !summary.action_items.isEmpty {
            let assigned = summary.action_items.contains { !($0.assignee_name ?? "").isEmpty }
            blocks.append(Block(24, keepWithNext: true) { SectionTitle(title: "Étapes suivantes", count: summary.action_items.count) }) // l10n:ignore
            for (index, action) in summary.action_items.enumerated() {
                var row = Block(0) { ActionRow(action: action, assigned: assigned, segments: segments(action.evidence_segment_ids), divider: index > 0) }
                row.atPageTop = AnyView(ActionRow(action: action, assigned: assigned, segments: segments(action.evidence_segment_ids), divider: false))
                blocks.append(row)
            }
        }
        if !details.isEmpty {
            blocks.append(Block(24, keepWithNext: true) { SectionTitle(title: "Détails", count: details.count) }) // l10n:ignore
            for topic in details {
                blocks.append(card(topic.title, topic.text, segments: segments(topic.evidence_segment_ids)))
            }
        }
        return blocks
    }

    static func header(_ item: Recording) -> Block {
        let date = item.startedAt.formatted(Date.FormatStyle(date: .long, time: .shortened).locale(Locale(identifier: "fr_FR")))
        var meta = ["\(max(1, Int(item.duration / 60))) min"]
        let names = item.participants.map(\.label)
        if !names.isEmpty { meta.append(names.joined(separator: ", ")) }
        let provenance = item.summaryProvenance.map { "Synthèse générée par " + $0.model + " le " + $0.generatedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "fr_FR"))) } // l10n:ignore
        return Block(0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(("Synthèse · " + item.kind.label + " · " + date).uppercased()).font(.system(size: Size.small, weight: .semibold)).tracking(1.2).foregroundStyle(Ink.muted) // l10n:ignore
                Text(item.title).font(.system(size: Size.title, weight: .semibold))
                Text(meta.joined(separator: " · ")).font(.system(size: Size.body)).foregroundStyle(Ink.muted)
                HStack(spacing: 6) {
                    Text(verbatim: item.isDemo ? "Synthèse fictive · exemple" : "Brouillon à relire").font(.system(size: Size.small, weight: .medium)) // l10n:ignore
                        .foregroundStyle(Ink.copper).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Ink.copper.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    if let provenance { Text(provenance).font(.system(size: Size.small)).foregroundStyle(Ink.muted) }
                }.padding(.top, 2)
                Rectangle().fill(Ink.line).frame(height: 0.5).padding(.top, 8)
            }
        }
    }

    /// A topic card, expanded. When taller than a page, it continues as paragraphs along a mint rule.
    static func card(_ title: String, _ text: String, segments: [TranscriptSegment]) -> Block {
        let paragraphs = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func ruled<V: View>(_ view: V) -> some View {
            view.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Ink.mint.opacity(0.3)).frame(width: 1.5) }
        }
        var split = [Block(8, keepWithNext: true) { ruled(TopicHead(title: title, segments: segments)) }]
        split += paragraphs.map { paragraph in Block(5) { ruled(Text(paragraph).font(.system(size: Size.body)).lineSpacing(3)) } }
        if segments.count > 1 { split.append(Block(6) { ruled(TopicFooter(segments: segments)) }) }
        return Block(6, split: split) { TopicCard(title: title, text: text, segments: segments) }
    }

    /// Summaries saved before summary-v4 only have their Markdown.
    static func legacy(_ markdown: String) -> [Block] {
        markdown.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.map { paragraph in
            if paragraph.hasPrefix("## ") { return Block(20, keepWithNext: true) { Text(String(paragraph.dropFirst(3))).font(.system(size: Size.heading, weight: .semibold)).foregroundStyle(Ink.mint) } }
            if paragraph.hasPrefix("### ") { return Block(10, keepWithNext: true) { Text(String(paragraph.dropFirst(4))).font(.system(size: Size.body, weight: .semibold)) } }
            return Block(6) { Text(paragraph).font(.system(size: Size.body)).lineSpacing(3) }
        }
    }

    // MARK: Components

    struct SectionTitle: View {
        let title: String, count: Int
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: Size.heading, weight: .semibold)).foregroundStyle(Ink.mint)
                Text(verbatim: "\(count)").font(.system(size: Size.small)).foregroundStyle(Ink.muted)
            }
        }
    }
    struct Chip: View {
        let count: Int, label: String
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: "\(count)").font(.system(size: Size.body, weight: .semibold))
                Text(label).font(.system(size: Size.small)).foregroundStyle(Ink.muted)
            }.padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Ink.line, lineWidth: 0.75))
        }
    }
    struct KeyPoint: View {
        let topic: SummaryTopic
        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(topic.title).font(.system(size: Size.body, weight: .semibold))
                Text(topic.text).font(.system(size: Size.small + 0.5)).foregroundStyle(Ink.muted).lineSpacing(2)
            }.padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Ink.tint, in: RoundedRectangle(cornerRadius: 6))
        }
    }
    /// Transcript time of the first passage, and how many others back the item.
    struct Source: View {
        let segments: [TranscriptSegment]
        var body: some View {
            if let first = segments.first {
                HStack(spacing: 2) {
                    Text(timeLabel(first.start))
                    if segments.count > 1 { Text(verbatim: "+\(segments.count - 1)").opacity(0.6) }
                }.font(.system(size: Size.small, design: .monospaced)).foregroundStyle(Ink.mint)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(Ink.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
            }
        }
    }
    struct Callout: View {
        let text: String, segments: [TranscriptSegment]
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(text).font(.system(size: Size.body)).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                Source(segments: segments)
            }.padding(.vertical, 7).padding(.leading, 12).padding(.trailing, 8)
            .background(Ink.tint, in: UnevenRoundedRectangle(bottomTrailingRadius: 5, topTrailingRadius: 5))
            .overlay(alignment: .leading) { Rectangle().fill(Ink.mint).frame(width: 2.5) }
        }
    }
    struct ActionRow: View {
        let action: SummaryAction, assigned: Bool, segments: [TranscriptSegment], divider: Bool
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                if assigned { Assignee(name: action.assignee_name) }
                VStack(alignment: .leading, spacing: 1) {
                    if let name = action.assignee_name, !name.isEmpty { Text(name).font(.system(size: Size.small, weight: .semibold)).foregroundStyle(Ink.muted) }
                    Text(action.text).font(.system(size: Size.body)).lineSpacing(3)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let due = action.due_date, !due.isEmpty {
                    Text(due).font(.system(size: Size.small, weight: .medium)).foregroundStyle(Ink.copper)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Ink.copper.opacity(0.08), in: RoundedRectangle(cornerRadius: 4)).fixedSize()
                }
                Source(segments: segments)
            }.padding(.vertical, 7)
            .overlay(alignment: .top) { if divider { Rectangle().fill(Ink.line).frame(height: 0.5) } }
        }
    }
    struct Assignee: View {
        let name: String?
        var body: some View {
            let initials = name.flatMap { name -> String? in
                let letters = name.split(whereSeparator: { $0 == " " || $0 == "-" }).prefix(2).compactMap(\.first)
                return letters.isEmpty ? nil : String(letters).uppercased()
            }
            ZStack {
                if let initials {
                    Circle().fill(Ink.mint)
                    Text(verbatim: initials).font(.system(size: Size.small - 1, weight: .bold)).foregroundStyle(.white)
                } else {
                    Circle().strokeBorder(Ink.line, style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
                }
            }.frame(width: 20, height: 20).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
        }
    }
    struct TopicHead: View {
        let title: String, segments: [TranscriptSegment]
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: Size.body + 0.5, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                if let first = segments.map(\.start).min(), let last = segments.map(\.end).max() {
                    Text(segments.count == 1 ? timeLabel(first) : timeLabel(first) + "–" + timeLabel(last))
                        .font(.system(size: Size.small, design: .monospaced)).foregroundStyle(Ink.muted)
                }
            }
        }
    }
    struct TopicFooter: View {
        let segments: [TranscriptSegment]
        var body: some View {
            if segments.count > 1 {
                HStack(spacing: 4) {
                    Text(verbatim: "Passages").font(.system(size: Size.small)).foregroundStyle(Ink.muted) // l10n:ignore
                    ForEach(segments.prefix(8)) { Source(segments: [$0]) }
                    if segments.count > 8 { Text(verbatim: "+\(segments.count - 8)").font(.system(size: Size.small)).foregroundStyle(Ink.muted) }
                }.padding(.top, 1)
            }
        }
    }
    struct TopicCard: View {
        let title: String, text: String, segments: [TranscriptSegment]
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                TopicHead(title: title, segments: segments)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph).font(.system(size: Size.body)).lineSpacing(3)
                    }
                }
                TopicFooter(segments: segments)
            }.padding(.horizontal, 12).padding(.vertical, 10)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.mint.opacity(0.3), lineWidth: 0.75))
        }
    }
}
