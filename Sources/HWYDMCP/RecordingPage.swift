import Foundation
import HWYDCore

/// Deterministic pages preserve segment boundaries. Only an oversized unit is fragmented.
struct RecordingPages {
    struct Unit {
        var artifact: String
        var text: String
        var segment: [String: Any]?
        var cost: Int
        var fragmented: Bool
    }
    var units: [Unit] = []
    var pages: [Range<Int>] = []
    var totalSegments: Int
    var totalCharacters: Int { units.reduce(0) { $0 + $1.cost } }

    init(recording: Recording, names: [String], input: [String: Any]) throws {
        let maximum = input["max_chars"] as? Int ?? 30000
        let segmentLimit = input["max_segments"] as? Int ?? 100
        let structured = input["format"] as? String == "structured"
        let from = (input["from"] as? NSNumber)?.doubleValue ?? 0
        let to = (input["to"] as? NSNumber)?.doubleValue ?? .infinity
        guard to > from else { throw IntegrationError("INVALID_ARGUMENTS") }
        let speakers = Dictionary(uniqueKeysWithValues: recording.speakers.map { ($0.id, $0) })
        let selected = recording.segments.filter { segment in
            guard segment.end > from, segment.start < to else { return false }
            if let track = input["track"] as? String, segment.source.rawValue != track { return false }
            if let id = input["speaker"] as? String, segment.speakerID?.uuidString.lowercased() != id.lowercased() { return false }
            if input["exclude_unattributed"] as? Bool == true, segment.speakerID == nil { return false }
            if input["exclude_echo_suspect"] as? Bool == true, segment.echoSuspect == true { return false }
            return true
        }.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start }
        totalSegments = selected.count
        for name in names {
            if name == "transcript" {
                for (index, segment) in selected.enumerated() {
                    if structured {
                        let speaker = segment.speakerID.flatMap { speakers[$0] }
                        let object: [String: Any] = ["id": segment.id.uuidString, "start": segment.start, "end": segment.end,
                            "track": segment.source.rawValue, "speaker_id": nullable(segment.speakerID?.uuidString),
                            "speaker_name": nullable(speaker?.label), "person_id": nullable(speaker?.personID?.uuidString),
                            "speaker_confirmed": speaker?.confirmed ?? false,
                            "confidence": NSNull(), "echo_suspect": nullable(segment.echoSuspect)]
                        try append(name, text: segment.text, segment: object, maximum: maximum)
                    } else {
                        var single = recording; single.segments = [segment]
                        let text = (index == 0 ? "" : "\n\n") + SessionExporter.artifact(single, "transcript")
                        try append(name, text: text, segment: nil, maximum: maximum)
                    }
                }
            } else if name != "summary" || recording.summary != nil {
                // Paragraph boundaries are preferred for prose artifacts too.
                let paragraphs = SessionExporter.artifact(recording, name).components(separatedBy: "\n\n")
                for (index, paragraph) in paragraphs.enumerated() {
                    try append(name, text: (index == 0 ? "" : "\n\n") + paragraph, segment: nil, maximum: maximum)
                }
            }
        }
        var start = 0, size = 0, count = 0
        for index in units.indices {
            if index > start && (size + units[index].cost > maximum || count >= segmentLimit) {
                pages.append(start..<index); start = index; size = 0; count = 0
            }
            size += units[index].cost; count += 1
        }
        pages.append(start..<units.count)
    }

    private mutating func append(_ artifact: String, text: String, segment: [String: Any]?, maximum: Int) throws {
        func make(_ part: String, offset: Int, fragmented: Bool) throws -> Unit {
            var object = segment
            if object != nil {
                object!["text"] = part
                object!["text_offset"] = offset
                object!["text_total_chars"] = text.count
                object!["partial"] = fragmented
            }
            return Unit(artifact: artifact, text: part, segment: object,
                        cost: try object.map { try json($0).count } ?? part.count, fragmented: fragmented)
        }
        let whole = try make(text, offset: 0, fragmented: false)
        if whole.cost <= maximum { units.append(whole); return }
        var offset = 0
        while offset < text.count {
            let remainder = String(text.dropFirst(offset))
            var low = 1, high = min(remainder.count, maximum), length = 0
            while low <= high {
                let middle = (low + high) / 2
                if try make(String(remainder.prefix(middle)), offset: offset, fragmented: true).cost <= maximum {
                    length = middle; low = middle + 1
                } else { high = middle - 1 }
            }
            guard length > 0 else { throw IntegrationError("PAGE_LIMIT_TOO_SMALL") }
            var part = String(remainder.prefix(length))
            if length < remainder.count, let boundary = part.lastIndex(where: \.isWhitespace) {
                let after = part.index(after: boundary)
                // Keep progress reasonable for pathological long words.
                if part.distance(from: part.startIndex, to: after) > length / 2 { part = String(part[..<after]) }
            }
            units.append(try make(part, offset: offset, fragmented: true)); offset += part.count
        }
    }
}
