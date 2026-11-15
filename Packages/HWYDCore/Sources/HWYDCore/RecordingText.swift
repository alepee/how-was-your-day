import Foundation

/// Plain text of a session's artifacts (notes, transcript, summary), shared by the search index,
/// the exports and `hwyd-mcp`. Ignored voices are left out of the transcript. Where recording
/// resumed, a marker line precedes the first passage after the resume.
public enum RecordingText {
    public static func artifact(_ item: Recording, _ name: String) -> String {
        switch name {
        case "notes": return item.noteEntries.sorted { $0.offset < $1.offset }.map { "- [\(timeLabel($0.offset, hours: true))] \($0.text)" }.joined(separator: "\n") + "\n\n" + item.notes
        case "summary": return item.summary ?? ""
        default:
            let segments = item.heardSegments.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
            let markers = SessionResume.markers(item.boundaries, before: segments)
            return segments.map { segment in
                let label = item.speakers.first { $0.id == segment.speakerID }?.label ?? "Voix inconnue"
                let line = "**[\(timeLabel(segment.start, hours: true)) - \(timeLabel(segment.end, hours: true))] \(escape(label)) (\(segment.source == .mic ? "micro" : "système"))** : \(segment.text)"
                return ((markers[segment.id] ?? []).map(resumeLine) + [line]).joined(separator: "\n\n")
            }.joined(separator: "\n\n")
        }
    }
    /// The line marking where recording resumed, before the passages that follow it.
    public static func resumeLine(_ resume: CaptureBoundary) -> String {
        "**[\(timeLabel(resume.offset, hours: true))] \(SessionResume.exportLabel(resume))**"
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}
