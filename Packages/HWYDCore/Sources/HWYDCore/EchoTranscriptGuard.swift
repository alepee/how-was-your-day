import Foundation

/// A review hint, not proof of acoustic echo. Never removes text or changes a speaker.
public enum EchoTranscriptGuard {
    public static let algorithm = "cross-track-text-review-v1"

    public static func annotate(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let system = segments.filter { $0.source == .system }.sorted { $0.start < $1.start }
        return segments.map { segment in
            var marked = segment
            marked.echoSuspect = false
            guard segment.source == .mic else { return marked }
            let words = tokens(segment.text)
            // Short acknowledgements and isolated words are normal in double talk.
            guard words.count >= 6, words.joined().count >= 24 else { return marked }
            let nearby = system.filter { $0.end >= segment.start - 5 && $0.start <= segment.end + 5 }
            // Test individually, then across a genuine adjacent system boundary.
            var candidates = nearby.map { tokens($0.text) }
            for index in nearby.indices.dropFirst() where nearby[index].start - nearby[index - 1].end <= 1 {
                candidates.append(tokens(nearby[index - 1].text + " " + nearby[index].text))
            }
            let allowed = words.count < 8 ? 0 : Int(Double(words.count) * 0.18)
            marked.echoSuspect = candidates.contains { substringDistance(words, $0) <= allowed }
            return marked
        }
    }

    private static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Edit distance to the best contiguous reference span. Free leading/trailing reference text.
    private static func substringDistance(_ query: [String], _ reference: [String]) -> Int {
        guard !reference.isEmpty else { return query.count }
        var previous = [Int](repeating: 0, count: reference.count + 1)
        for (index, word) in query.enumerated() {
            var row = [Int](repeating: 0, count: reference.count + 1)
            row[0] = index + 1
            for column in 1...reference.count {
                row[column] = min(previous[column] + 1, row[column - 1] + 1,
                                  previous[column - 1] + (word == reference[column - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous.min() ?? query.count
    }
}
