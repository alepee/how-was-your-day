import Foundation

/// Geometry shared by the voice post-processing and voice memory: usable speech, overlap between
/// tracks, similarity of voice embeddings, and the split of one voice in two groups.
public enum VoiceCoherence {
    public struct Span: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public init(start: Double, end: Double) { self.start = start; self.end = end }
        public var duration: Double { end - start }
    }

    /// Sorted spans with the overlapping ones merged.
    public static func union(_ spans: [Span]) -> [Span] {
        var result: [Span] = []
        for span in spans.sorted(by: { $0.start < $1.start }) where span.end > span.start {
            if let last = result.indices.last, span.start <= result[last].end { result[last].end = max(result[last].end, span.end) }
            else { result.append(span) }
        }
        return result
    }
    public static func seconds(_ spans: [Span]) -> Double { union(spans).reduce(0) { $0 + $1.duration } }
    /// Seconds of `span` covered by `spans`, which must come from `union`.
    public static func overlap(_ span: Span, with spans: [Span]) -> Double {
        spans.reduce(0) { $0 + max(0, min(span.end, $1.end) - max(span.start, $1.start)) }
    }

    /// At most `total` seconds of `spans`, taken as `pieces` slices spread evenly over the speech, so a
    /// sample represents the whole voice and not only its first minute.
    public static func spread(_ spans: [Span], total: Double = 60, pieces: Int = 6) -> [Span] {
        let spans = union(spans)
        let available = spans.reduce(0) { $0 + $1.duration }
        guard available > total, pieces > 0 else { return spans }
        let slice = total / Double(pieces), stride = available / Double(pieces)
        var result: [Span] = []
        for piece in 0..<pieces {
            // Slice `piece` covers [from, from + slice) on the axis of cumulated speech.
            let from = Double(piece) * stride, to = from + slice
            var cursor = 0.0
            for span in spans {
                let low = max(from, cursor), high = min(to, cursor + span.duration)
                if high > low { result.append(Span(start: span.start + low - cursor, end: span.start + high - cursor)) }
                cursor += span.duration
                if cursor >= to { break }
            }
        }
        return union(result)
    }

    /// Segments of `speaker` usable for a voice sample: at least 0.5 s, and not overlapping another
    /// voice of the same track. Sorted by start.
    public static func usableSegments(of speaker: UUID, in segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.filter { $0.speakerID == speaker }.sorted { $0.start < $1.start }.filter { segment in
            segment.end - segment.start >= 0.5 && !segments.contains {
                $0.id != segment.id && $0.source == segment.source && $0.speakerID != segment.speakerID
                    && $0.start < segment.end && $0.end > segment.start
            }
        }
    }

    /// Speech of `speaker` that falls while another track speaks: the share of its speech time, and
    /// the seconds shared with each voice of that other track.
    public static func crossTrackOverlap(of speaker: UUID, in segments: [TranscriptSegment]) -> (share: Double, byVoice: [UUID: Double]) {
        let own = segments.filter { $0.speakerID == speaker }
        guard let source = own.first?.source else { return (0, [:]) }
        let others = segments.filter { $0.source != source }.sorted { $0.start < $1.start }
        var total = 0.0, covered = 0.0
        var byVoice: [UUID: Double] = [:]
        for segment in own {
            total += segment.end - segment.start
            var end = segment.start
            for other in others where other.start < segment.end && other.end > segment.start {
                let from = max(segment.start, other.start), to = min(segment.end, other.end)
                if let id = other.speakerID { byVoice[id, default: 0] += to - from }
                covered += max(0, to - max(end, from)); end = max(end, to)
            }
        }
        return (total > 0 ? covered / total : 0, byVoice)
    }

    /// Level of a block of samples in dBFS, floored at -120.
    public static func levelDB(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return max(-120, 10 * log10(max(power, 1e-12)))
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for (x, y) in zip(a, b) { dot += Double(x * y); na += Double(x * x); nb += Double(y * y) }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : -1
    }

    /// Weighted mean direction of unit vectors.
    public static func centroid(_ vectors: [[Float]], weights: [Double]) -> [Float] {
        guard let dimension = vectors.first?.count else { return [] }
        var sum = [Double](repeating: 0, count: dimension)
        for (vector, weight) in zip(vectors, weights) {
            let norm = vector.reduce(0.0) { $0 + Double($1 * $1) }.squareRoot()
            guard norm > 0 else { continue }
            for index in 0..<dimension { sum[index] += weight * Double(vector[index]) / norm }
        }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return sum.map { Float(norm > 0 ? $0 / norm : 0) }
    }

    public struct Split: Equatable, Sendable {
        /// Group index (0 or 1) for each input vector.
        public var assignment: [Int]
        /// Cosine between the two group centroids. Low means two different voices.
        public var between: Double
    }

    /// Splits the vectors into two groups: spherical 2-means, seeded with the two least similar
    /// vectors, weighted by block duration. Deterministic.
    public static func split(_ vectors: [[Float]], weights: [Double], iterations: Int = 50) -> Split? {
        guard vectors.count >= 2, vectors.count == weights.count else { return nil }
        var seeds = (0, 1), lowest = Double.infinity
        for i in vectors.indices { for j in vectors.indices where j > i {
            let value = cosine(vectors[i], vectors[j])
            if value < lowest { lowest = value; seeds = (i, j) }
        } }
        var centroids = [vectors[seeds.0], vectors[seeds.1]]
        var assignment = [Int](repeating: -1, count: vectors.count)
        for _ in 0..<iterations {
            let next = vectors.map { cosine($0, centroids[0]) >= cosine($0, centroids[1]) ? 0 : 1 }
            guard next != assignment else { break }
            assignment = next
            for group in 0...1 {
                let members = vectors.indices.filter { assignment[$0] == group }
                guard !members.isEmpty else { return nil }
                centroids[group] = centroid(members.map { vectors[$0] }, weights: members.map { weights[$0] })
            }
        }
        return Split(assignment: assignment, between: cosine(centroids[0], centroids[1]))
    }
}
