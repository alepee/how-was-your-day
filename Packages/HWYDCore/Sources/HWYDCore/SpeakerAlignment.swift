import Foundation

public struct SpeakerTurn: Sendable {
    public var cluster: String
    public var source: AudioSource
    public var start: Double
    public var end: Double
    public init(cluster: String, source: AudioSource, start: Double, end: Double) {
        self.cluster = cluster; self.source = source; self.start = start; self.end = end
    }
}
public protocol OfflineDiarizing: Sendable {
    func diarize(file: URL, source: AudioSource) async throws -> [SpeakerTurn]
}
public enum SpeakerAlignment {
    /// Match timed words only. A tie or a missing timestamp deliberately stays unattributed.
    public static func apply(segments: [TranscriptSegment], turns: [SpeakerTurn]) -> (segments: [TranscriptSegment], speakers: [Speaker]) {
        let valid = turns.filter { !$0.cluster.isEmpty && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
        var speakers: [Speaker] = []
        var ids: [String: UUID] = [:]
        var output: [TranscriptSegment] = []
        for original in segments {
            guard let words = original.words, !words.isEmpty,
                  words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }),
                  words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == original.text.trimmingCharacters(in: .whitespacesAndNewlines)
            else { var unchanged = original; unchanged.speakerID = nil; output.append(unchanged); continue }
            var runs: [(cluster: String?, words: [TranscriptWord])] = []
            for word in words {
                var intervals: [String: [(Double, Double)]] = [:]
                for turn in valid where turn.source == original.source && turn.start < word.end && turn.end > word.start {
                    intervals[turn.cluster, default: []].append((max(word.start, turn.start), min(word.end, turn.end)))
                }
                let scores = intervals.map { key, ranges -> (String, Double) in
                    var end = -Double.infinity, total = 0.0
                    for range in ranges.sorted(by: { $0.0 < $1.0 }) {
                        total += max(0, range.1 - max(end, range.0)); end = max(end, range.1)
                    }
                    return (key, total)
                }.sorted { $0.1 > $1.1 }
                let cluster = scores.first.flatMap { best in scores.count == 1 || best.1 - scores[1].1 > 0.000001 ? best.0 : nil }
                if let last = runs.indices.last, runs[last].cluster == cluster { runs[last].words.append(word) }
                else { runs.append((cluster, [word])) }
            }
            // Absorb a brief interior turn only when both neighbours agree, within the same track.
            if runs.count >= 3 {
                for index in 1..<(runs.count - 1) {
                    let run = runs[index]
                    if run.cluster != nil, let first = run.words.first, let last = run.words.last,
                       last.end - first.start < 0.5, let surrounding = runs[index-1].cluster,
                       surrounding == runs[index+1].cluster { runs[index].cluster = surrounding }
                }
            }
            var merged: [(cluster: String?, words: [TranscriptWord])] = []
            for run in runs {
                if let last = merged.indices.last, merged[last].cluster == run.cluster { merged[last].words += run.words }
                else { merged.append(run) }
            }
            for run in merged {
                var id: UUID?
                if let cluster = run.cluster {
                    let key = original.source.rawValue + ":" + cluster
                    if ids[key] == nil {
                        let speaker = Speaker(label: "Voix \(speakers.count + 1)", source: original.source)
                        ids[key] = speaker.id; speakers.append(speaker)
                    }
                    id = ids[key]
                }
                let text = run.words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                var segment = TranscriptSegment(start: run.words.first!.start, end: run.words.last!.end, speakerID: id, source: original.source, text: text)
                segment.words = run.words; output.append(segment)
            }
        }
        return (output.sorted { $0.start < $1.start }, speakers)
    }
}
