import Foundation

extension TranscriptSegment {
    /// Only expose boundaries supported by the original ASR timestamps and complete text.
    public var splitIndices: [Int] {
        guard let words, words.count > 1,
              words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == text.trimmingCharacters(in: .whitespacesAndNewlines),
              words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= start && $0.end <= end && $0.end > $0.start }),
              zip(words, words.dropFirst()).allSatisfy({ $0.start <= $1.start && $0.end <= $1.end }) else { return [] }
        return (1..<words.count).filter { index in
            words[index - 1].end <= words[index].start &&
            !words[..<index].map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !words[index...].map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

extension Recording {
    public mutating func splitSegment(_ segmentID: UUID, beforeWord index: Int) throws {
        guard let position = segments.firstIndex(where: { $0.id == segmentID }) else { throw StoreError.notFound }
        let original = segments[position]
        guard original.splitIndices.contains(index), let words = original.words else { throw TranscriptEditingError.invalidBoundary }
        let leftWords = Array(words[..<index]), rightWords = Array(words[index...])
        var left = original
        left.words = leftWords
        left.text = leftWords.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        left.end = leftWords.last!.end
        var right = TranscriptSegment(start: rightWords.first!.start, end: original.end,
                                      speakerID: original.speakerID, source: original.source,
                                      text: rightWords.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines))
        right.words = rightWords
        segments.replaceSubrange(position...position, with: [left, right])
        transcriptVersion += 1
        summary = nil
    }
}

public enum TranscriptEditingError: LocalizedError {
    case invalidBoundary
    public var errorDescription: String? { "Les horodatages ne permettent pas de découper ce passage à cet endroit." }
}
