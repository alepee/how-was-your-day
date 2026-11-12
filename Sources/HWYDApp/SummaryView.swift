import SwiftUI
import HWYDCore

/// Sections of a structured summary, in reading order. Used for scrolling and the outline.
private enum SummaryAnchor: Hashable {
    case overview, decisions, actions, details, context
    case topic(Int), note(Int)
}

/// Structured summary: a bounded reading column, compact source references and
/// collapsible topics, with an outline beside it when the pane is wide enough.
struct SummaryPane<Header: View>: View {
    @EnvironmentObject var model: AppModel
    let recording: Recording
    let header: Header
    @State private var expanded: Set<SummaryAnchor> = []
    @State private var visible: Set<SummaryAnchor> = []
    @State private var paneWidth: CGFloat = 0
    /// Reading width of the summary column, about 75 characters at body size.
    static var readingWidth: CGFloat { 640 }
    static var outlineWidth: CGFloat { 238 }

    var body: some View {
        let structured = recording.summary == nil ? nil : recording.summaryProvenance?.structured
        ScrollViewReader { proxy in
            // The outline sits right after the reading column and does not scroll with it.
            ZStack(alignment: .topLeading) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        header
                        if let structured, structured.details != nil {
                            content(structured, proxy: proxy)
                        } else {
                            legacy
                        }
                    }.frame(maxWidth: Self.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(32).padding(.top, 0)
                }
                if let structured, structured.details != nil, paneWidth >= Self.readingWidth + 64 + Self.outlineWidth {
                    outline(structured, proxy: proxy).padding(.leading, Self.readingWidth + 64)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
        .onAppear { resetExpansion(structured) }
        .onChange(of: recording.summaryProvenance?.generatedAt) { _, _ in resetExpansion(recording.summaryProvenance?.structured) }
    }

    /// Short summaries open every topic; long ones start folded so the outline stays readable.
    private func resetExpansion(_ structured: SummaryContent?) {
        guard let structured else { expanded = []; return }
        let topics = (structured.details ?? []).indices.map { SummaryAnchor.topic($0) }
        expanded = topics.count <= 3 ? Set(topics) : []
    }

    // MARK: Content

    @ViewBuilder private func content(_ summary: SummaryContent, proxy: ScrollViewProxy) -> some View {
        let details = summary.details ?? []
        let context = summary.context ?? []
        VStack(alignment: .leading, spacing: 14) {
            Text(summary.overview).font(.system(size: Studio.Size.heading)).lineSpacing(5).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if !summary.decisions.isEmpty { statButton(summary.decisions.count, summary.decisions.count == 1 ? String(localized: "décision") : String(localized: "décisions"), .decisions, proxy) }
                if !summary.action_items.isEmpty { statButton(summary.action_items.count, summary.action_items.count == 1 ? String(localized: "action") : String(localized: "actions"), .actions, proxy) }
                if !details.isEmpty { statButton(details.count, details.count == 1 ? String(localized: "thème") : String(localized: "thèmes"), .details, proxy) }
                if !context.isEmpty { statButton(context.count, context.count == 1 ? String(localized: "note de contexte") : String(localized: "notes de contexte"), .context, proxy) }
            }
            if let points = summary.key_points, !points.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8, alignment: .top), GridItem(.flexible(), spacing: 8, alignment: .top)], alignment: .leading, spacing: 8) {
                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in keyPoint(point) }
                }
            }
        }.id(SummaryAnchor.overview).tracked(.overview, in: $visible)

        if !summary.decisions.isEmpty {
            section("Décisions", count: summary.decisions.count, anchor: .decisions)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(summary.decisions.enumerated()), id: \.offset) { _, decision in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(decision.text).font(.system(size: Studio.Size.body)).lineSpacing(4).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SourceButton(segments: segments(decision.evidence_segment_ids))
                    }.padding(.vertical, 9).padding(.horizontal, 12)
                    .background(Studio.surface, in: UnevenRoundedRectangle(bottomTrailingRadius: 7, topTrailingRadius: 7))
                    .overlay(alignment: .leading) { Rectangle().fill(Studio.mint).frame(width: 3) }
                }
            }
        }

        if !summary.action_items.isEmpty {
            section("Étapes suivantes", count: summary.action_items.count, anchor: .actions)
            VStack(spacing: 0) {
                let assigned = summary.action_items.contains { !($0.assignee_name ?? "").isEmpty }
                ForEach(Array(summary.action_items.enumerated()), id: \.offset) { index, action in
                    actionRow(action, assigned: assigned)
                    if index < summary.action_items.count - 1 { Divider().overlay(Studio.line) }
                }
            }
        }

        if !details.isEmpty {
            HStack {
                section("Détails", count: details.count, anchor: .details)
                Spacer()
                let all = Set(details.indices.map { SummaryAnchor.topic($0) })
                Button(all.isSubset(of: expanded) ? "Tout replier" : "Tout déplier") {
                    withAnimation(.easeOut(duration: 0.15)) { if all.isSubset(of: expanded) { expanded.subtract(all) } else { expanded.formUnion(all) } }
                }.buttonStyle(StudioButtonStyle(compact: true)).padding(.top, 12)
            }
            VStack(spacing: 6) {
                ForEach(Array(details.enumerated()), id: \.offset) { index, topic in
                    TopicCard(title: topic.title, text: topic.text, segments: segments(topic.evidence_segment_ids), footer: nil,
                              isExpanded: binding(.topic(index)))
                        .id(SummaryAnchor.topic(index)).tracked(.topic(index), in: $visible)
                }
            }
        }

        if !context.isEmpty {
            HStack(spacing: 2) {
                section("Contexte", count: context.count, anchor: .context)
                HelpButton(text: String(localized: "Apports de votre agent, tirés de ce qu’il sait de vous et de vos projets. Ils ne viennent pas de la conversation.")).padding(.top, 12)
            }
            VStack(spacing: 6) {
                ForEach(Array(context.enumerated()), id: \.offset) { index, note in
                    TopicCard(title: note.title, text: note.text, segments: [],
                              footer: note.sources.isEmpty ? nil : String(localized: "Sources : \(note.sources.joined(separator: ", "))"),
                              isExpanded: binding(.note(index)))
                        .id(SummaryAnchor.note(index)).tracked(.note(index), in: $visible)
                }
            }
        }
        if recording.isDemo { Badge(text: String(localized: "SYNTHÈSE FICTIVE · EXEMPLE D’INTERFACE")).padding(.top, 15) }
    }

    /// Summaries saved before summary-v4 only have their Markdown.
    @ViewBuilder private var legacy: some View {
        if let summary = recording.summary {
            ForEach(Array(summary.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                if paragraph.hasPrefix("### ") { Text(String(paragraph.dropFirst(4))).font(.system(size: Studio.Size.body, weight: .semibold)).padding(.top, 6) }
                else if paragraph.hasPrefix("## ") { Text(paragraph.replacingOccurrences(of: "## ", with: "")).font(.system(size: Studio.Size.heading, weight: .medium)).foregroundStyle(Studio.mint).padding(.top, 12) }
                else { Text(paragraph).font(.system(size: Studio.Size.body)).lineSpacing(7).textSelection(.enabled) }
            }
            if recording.isDemo { Badge(text: String(localized: "SYNTHÈSE FICTIVE · EXEMPLE D’INTERFACE")).padding(.top, 15) }
        }
    }

    private func section(_ title: LocalizedStringKey, count: Int, anchor: SummaryAnchor) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: Studio.Size.heading, weight: .semibold)).foregroundStyle(Studio.mint)
            Text(count, format: .number).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
        }.padding(.top, 12).id(anchor).tracked(anchor, in: $visible)
    }

    private func statButton(_ count: Int, _ label: String, _ anchor: SummaryAnchor, _ proxy: ScrollViewProxy) -> some View {
        Button { withAnimation { proxy.scrollTo(anchor, anchor: .top) } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(count, format: .number).font(.system(size: Studio.Size.body, weight: .semibold)).foregroundStyle(Studio.text)
                Text(label).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
            }.padding(.horizontal, 10).padding(.vertical, 6)
            .background(Studio.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Studio.line))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
    }

    private func keyPoint(_ point: SummaryTopic) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(point.title).font(.system(size: Studio.Size.body, weight: .semibold))
            Text(point.text).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }.textSelection(.enabled).padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Studio.surface, in: RoundedRectangle(cornerRadius: 7))
    }

    /// `assigned`: some action in the list names a person, so every row keeps the mark column.
    private func actionRow(_ action: SummaryAction, assigned: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if assigned { AssigneeMark(name: action.assignee_name) }
            Text(action.text).font(.system(size: Studio.Size.body)).lineSpacing(4).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let due = action.due_date, !due.isEmpty { Badge(text: due, color: Studio.copper) }
            SourceButton(segments: segments(action.evidence_segment_ids))
        }.padding(.vertical, 9)
    }

    private func segments(_ ids: [UUID]) -> [TranscriptSegment] {
        let wanted = Set(ids)
        return recording.segments.filter { wanted.contains($0.id) }.sorted { $0.start < $1.start }
    }

    private func binding(_ anchor: SummaryAnchor) -> Binding<Bool> {
        Binding(get: { expanded.contains(anchor) }, set: { open in
            withAnimation(.easeOut(duration: 0.15)) { if open { expanded.insert(anchor) } else { expanded.remove(anchor) } }
        })
    }

    // MARK: Outline

    /// Sections and topics, beside the reading column. Hidden when the pane is too narrow for both.
    private func outline(_ summary: SummaryContent, proxy: ScrollViewProxy) -> some View {
        let details = summary.details ?? []
        let context = summary.context ?? []
        var order: [SummaryAnchor] = [.overview]
        if !summary.decisions.isEmpty { order.append(.decisions) }
        if !summary.action_items.isEmpty { order.append(.actions) }
        if !details.isEmpty { order.append(.details); order += details.indices.map { .topic($0) } }
        if !context.isEmpty { order.append(.context); order += context.indices.map { .note($0) } }
        let current = order.first { visible.contains($0) }
        func jump(_ anchor: SummaryAnchor) {
            if case .topic = anchor { expanded.insert(anchor) }
            if case .note = anchor { expanded.insert(anchor) }
            withAnimation { proxy.scrollTo(anchor, anchor: .top) }
        }
        return ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    outlineRow(String(localized: "Résumé"), .overview, current: current, strong: true, action: jump)
                    if !summary.decisions.isEmpty { outlineRow(String(localized: "Décisions"), .decisions, current: current, strong: true, action: jump) }
                    if !summary.action_items.isEmpty { outlineRow(String(localized: "Étapes suivantes"), .actions, current: current, strong: true, action: jump) }
                    if !details.isEmpty {
                        outlineRow(String(localized: "Détails"), .details, current: current, strong: true, action: jump)
                        ForEach(Array(details.enumerated()), id: \.offset) { index, topic in
                            outlineRow(topic.title, .topic(index), current: current, strong: false, action: jump)
                        }
                    }
                    if !context.isEmpty {
                        outlineRow(String(localized: "Contexte"), .context, current: current, strong: true, action: jump)
                        ForEach(Array(context.enumerated()), id: \.offset) { index, note in
                            outlineRow(note.title, .note(index), current: current, strong: false, action: jump)
                        }
                    }
                }.padding(.vertical, 4)
            }.scrollIndicators(.never).frame(width: 200).padding(.leading, 14).padding(.trailing, 24)
            .overlay(alignment: .leading) { Rectangle().fill(Studio.line).frame(width: 0.5) }
            .accessibilityLabel("Plan de la synthèse")
    }

    private func outlineRow(_ title: String, _ anchor: SummaryAnchor, current: SummaryAnchor?, strong: Bool, action: @escaping (SummaryAnchor) -> Void) -> some View {
        let isCurrent = current == anchor
        return Button { action(anchor) } label: {
            Text(title).font(.system(size: Studio.Size.caption, weight: strong ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(isCurrent ? Studio.mint : strong ? Studio.text : Studio.muted)
                .padding(.horizontal, 8).padding(.vertical, 4).padding(.top, strong && anchor != .overview ? 8 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isCurrent ? Studio.mint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(title)
    }
}

private extension View {
    /// Keeps `visible` up to date with the anchors on screen, for the outline highlight.
    func tracked(_ anchor: SummaryAnchor, in visible: Binding<Set<SummaryAnchor>>) -> some View {
        onScrollVisibilityChange(threshold: 0.05) { shown in
            if shown { visible.wrappedValue.insert(anchor) } else { visible.wrappedValue.remove(anchor) }
        }
    }
}

/// A topic or a context note: title, time span and first sentence when folded; full text and passages when open.
private struct TopicCard: View {
    let title: String
    let text: String
    let segments: [TranscriptSegment]
    let footer: String?
    @Binding var isExpanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isExpanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: Studio.Size.caption, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0)).foregroundStyle(isExpanded ? Studio.mint : Studio.muted).frame(width: 12)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: Studio.Size.body, weight: .semibold)).foregroundStyle(Studio.text)
                        if !isExpanded {
                            Text(Self.lede(text)).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).lineLimit(1).truncationMode(.tail)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let span { Text(span).font(.system(size: Studio.Size.caption, design: .monospaced)).foregroundStyle(Studio.muted) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityHint(isExpanded ? Text("Replier") : Text("Déplier"))
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(text).font(.system(size: Studio.Size.body)).lineSpacing(6).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if !segments.isEmpty {
                        HStack(spacing: 6) { ForEach(segments) { SourceButton(segments: [$0]) } }
                    }
                    if let footer { Text(footer).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).textSelection(.enabled) }
                }.padding(.leading, 22)
            }
        }.padding(.horizontal, 12).padding(.vertical, 10)
        .background(isExpanded ? Studio.background : Studio.surface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(isExpanded ? Studio.mint.opacity(0.35) : Studio.line))
    }
    /// Range covered by the topic's passages, from the first start to the last end.
    private var span: String? {
        guard let first = segments.map(\.start).min(), let last = segments.map(\.end).max() else { return nil }
        return segments.count == 1 ? timeLabel(first) : timeLabel(first) + "–" + timeLabel(last)
    }
    /// First sentence, so a folded topic still says what it is about.
    static func lede(_ text: String) -> String {
        var end = text.endIndex
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { _, range, _, stop in end = range.upperBound; stop = true }
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// One compact reference to the transcript: the first passage's time and how many others back the item.
/// Hover lists the passages, a click moves playback to the first one.
private struct SourceButton: View {
    @EnvironmentObject var model: AppModel
    let segments: [TranscriptSegment]
    var body: some View {
        if let first = segments.first {
            Button { model.seekPlayback(to: first.start) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill").font(.system(size: 7))
                    Text(timeLabel(first.start))
                    if segments.count > 1 { Text(verbatim: "+\(segments.count - 1)").opacity(0.6) }
                }.font(.system(size: Studio.Size.caption, design: .monospaced)).foregroundStyle(Studio.mint)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Studio.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Studio.mint.opacity(0.2)))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).fixedSize()
            .help(segments.map { timeLabel($0.start) + " · " + $0.text }.joined(separator: "\n\n"))
            .accessibilityLabel(Text("Aller au passage \(timeLabel(first.start))"))
        }
    }
}

/// Initials of the person an action is assigned to, or an empty mark when nobody is named.
private struct AssigneeMark: View {
    let name: String?
    var body: some View {
        ZStack {
            if let initials {
                Circle().fill(Studio.mint)
                Text(verbatim: initials).font(.system(size: Studio.Size.caption, weight: .bold)).foregroundStyle(Studio.onAccent)
            } else {
                Circle().strokeBorder(Studio.line, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }.frame(width: 24, height: 24).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        .help(name ?? String(localized: "Aucune personne désignée"))
        .accessibilityHidden(true)
    }
    private var initials: String? {
        guard let name, !name.isEmpty else { return nil }
        let letters = name.split(whereSeparator: { $0 == " " || $0 == "-" }).prefix(2).compactMap(\.first)
        return letters.isEmpty ? nil : String(letters).uppercased()
    }
}
