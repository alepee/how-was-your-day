import Foundation

/// Plain text of a session's artifacts (notes, transcript, summary), shared by the search index,
/// the exports and `hwyd-mcp`. Ignored voices are left out of the transcript.
public enum RecordingText {
    public static func artifact(_ item: Recording, _ name: String) -> String {
        switch name {
        case "notes": return item.noteEntries.sorted { $0.offset < $1.offset }.map { "- [\(timeLabel($0.offset, hours: true))] \($0.text)" }.joined(separator: "\n") + "\n\n" + item.notes
        case "summary": return item.summary ?? ""
        default:
            return item.heardSegments.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }.map { segment in
                let label = item.speakers.first { $0.id == segment.speakerID }?.label ?? "Voix inconnue"
                return "**[\(timeLabel(segment.start, hours: true)) - \(timeLabel(segment.end, hours: true))] \(escape(label)) (\(segment.source == .mic ? "micro" : "système"))** : \(segment.text)"
            }.joined(separator: "\n\n")
        }
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}
