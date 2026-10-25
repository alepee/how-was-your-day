import Foundation

public struct CalendarParticipant: Codable, Equatable, Sendable {
    public var name: String?
    public var email: String?
    public init(name: String?, email: String?) { self.name = name; self.email = email }
}

public struct CalendarContext: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var calendarTitle: String
    public var details: String?
    public var location: String?
    public var meetingURL: URL?
    public var participants: [CalendarParticipant]
    public init(id: String, title: String, start: Date, end: Date, calendarTitle: String, details: String? = nil, location: String? = nil, meetingURL: URL? = nil, participants: [CalendarParticipant] = []) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.calendarTitle = calendarTitle
        self.details = details; self.location = location; self.meetingURL = meetingURL; self.participants = participants
    }
}

public enum MeetingRules {
    public static func isExcluded(title: String, keywords: String) -> Bool {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        return keywords.split(separator: ",").contains { keyword in
            let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
            guard !word.isEmpty else { return false }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
            return folded.range(of: pattern, options: .regularExpression) != nil
        }
    }
    public static func meetingURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url).first { url in
            guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
            return ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com"].contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
    public static func reminderDate(start: Date, minutes: Int, now: Date) -> Date? {
        let date = start.addingTimeInterval(-Double(max(0, minutes)) * 60)
        return date > now ? date : nil
    }
}
