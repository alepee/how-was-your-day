import Foundation
import GRDB

/// Where a voice was heard. The microphone and the call audio sound different enough
/// (Opus, automatic gain) for one voice to score like two people, so each keeps its own exemplars.
public enum VoiceChannel: String, Codable, CaseIterable, Sendable {
    case mic, remote
    public init(source: AudioSource) { self = source == .system ? .remote : .mic }
    /// Before 0.9 the microphone was split into `near` (the user) and `room` (others in the room).
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "mic", "near", "room": self = .mic
        case "remote": self = .remote
        default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown voice channel \(raw)"))
        }
    }
    public var other: VoiceChannel { self == .mic ? .remote : .mic }
    public var label: String { self == .mic ? String(localized: "Micro", bundle: .hwyd) : String(localized: "Visio", bundle: .hwyd) }
}
public struct VoicePerson: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var consentedAt: Date?
    /// Explicit local enrollment action, distinct from a legal consent attestation.
    public var enrollmentRequestedAt: Date?
    public var enrolledChannels: [VoiceChannel]?
    public var lastEnrolledAt: Date?
    public var recognitionEnabled: Bool { !opposed && (consentedAt != nil || enrollmentRequestedAt != nil) }
    public var opposed: Bool
    /// Enrolled channels without the duplicates left by the former near/room split.
    public var channels: [VoiceChannel] { VoiceChannel.allCases.filter { (enrolledChannels ?? []).contains($0) } }
    public init(id: UUID = UUID(), name: String, consentedAt: Date? = nil, opposed: Bool = false) {
        self.id = id; self.name = name; self.consentedAt = consentedAt; self.opposed = opposed
    }
}
public struct VoiceMatch: Codable, Equatable, Sendable {
    public var personID: UUID
    /// Acoustic score, a mean cosine.
    public var score: Double
    public var margin: Double?
    /// Channel of the exemplars that matched.
    public var channel: VoiceChannel
    /// The person had no exemplar on this voice's channel; the other one matched a stricter threshold.
    public var crossChannel: Bool?
    public init(personID: UUID, score: Double, margin: Double?, channel: VoiceChannel, crossChannel: Bool = false) {
        self.personID = personID; self.score = score; self.margin = margin; self.channel = channel; self.crossChannel = crossChannel
    }
}
/// One stored voice sample and where it came from, so a session's contribution can be withdrawn.
/// Lives only in the keychain, like the vector itself.
public struct VoiceExemplar: Codable, Equatable, Sendable {
    public var vector: [Float]
    /// nil for samples stored before 0.9, whose origin is unknown.
    public var recordingID: UUID?
    public var speakerID: UUID?
    public var addedAt: Date?
    public init(vector: [Float], recordingID: UUID? = nil, speakerID: UUID? = nil, addedAt: Date? = nil) {
        self.vector = vector; self.recordingID = recordingID; self.speakerID = speakerID; self.addedAt = addedAt
    }
}
/// What a session added to a person's voice print. Carries no vector.
public struct VoiceContribution: Codable, Equatable, Identifiable, Sendable {
    /// nil groups the samples stored before 0.9, whose origin is unknown.
    public var recordingID: UUID?
    public var channel: VoiceChannel
    public var count: Int
    public var addedAt: Date?
    public var id: String { (recordingID?.uuidString ?? "unknown") + "." + channel.rawValue }
    public init(recordingID: UUID?, channel: VoiceChannel, count: Int, addedAt: Date?) {
        self.recordingID = recordingID; self.channel = channel; self.count = count; self.addedAt = addedAt
    }
}
public struct VoiceJob: Codable, Sendable {
    public var recording: Recording
    public var speakerID: UUID?
    public var personID: UUID?
    /// For `forget-voice-source`: the session whose samples are withdrawn, nil for samples of unknown origin.
    public var sourceRecordingID: UUID?
    public init(recording: Recording, speakerID: UUID? = nil, personID: UUID? = nil, sourceRecordingID: UUID? = nil) {
        self.recording = recording; self.speakerID = speakerID; self.personID = personID; self.sourceRecordingID = sourceRecordingID
    }
}
public enum VoiceError: LocalizedError {
    case consentRequired, invalidVector, keychain(OSStatus), insufficientSpeech
    public var errorDescription: String? {
        switch self {
        case .consentRequired: String(localized: "La mémorisation de cette personne n’est pas activée ou une opposition est active.", bundle: .hwyd)
        case .invalidVector: String(localized: "Empreinte vocale invalide.", bundle: .hwyd)
        case .keychain(let status): String(localized: "Trousseau indisponible (\(status)). Aucune empreinte exportée.", bundle: .hwyd)
        case .insufficientSpeech: String(localized: "Il faut au moins 20 secondes de parole propre pour cette voix, sans chevauchement.", bundle: .hwyd)
        }
    }
}
/// Voice prints of known people, one secret per person and channel in the
/// `dev.lepee.hwyd.voice.we-speaker-v1` service. Vectors never enter SQLite, job files, exports or
/// logs; `hwyd-pipeline` alone reads them, through the vault it is given.
public struct VoicePrints: Sendable {
    public static let service = "dev.lepee.hwyd.voice.we-speaker-v1"
    public static let exemplarLimit = 20
    /// Accounts of the former microphone split, folded into `mic` on first read.
    static let legacyAccounts: [VoiceChannel: [String]] = [.mic: ["near", "room"], .remote: []]
    public let vault: any SecretVault
    public init(vault: any SecretVault) { self.vault = vault }

    /// The vault item of one person's account (a channel, or a former one).
    public static func item(_ person: UUID, _ account: String) -> SecretItem {
        SecretItem(service: service, account: person.uuidString + "." + account)
    }
    private func mapped<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let failure as SecretVaultFailure { throw VoiceError.keychain(failure.status) }
    }
    private func read(_ person: UUID, _ account: String) throws -> [VoiceExemplar] {
        guard let data = try mapped({ try vault.read(Self.item(person, account)) }) else { return [] }
        return try Self.decode(data)
    }
    private func write(_ values: [VoiceExemplar], _ person: UUID, _ account: String) throws {
        guard !values.isEmpty else { return try delete(person, account) }
        let data = try JSONEncoder().encode(values)
        try mapped { try vault.write(data, for: Self.item(person, account)) }
    }
    private func delete(_ person: UUID, _ account: String) throws {
        try mapped { try vault.remove(Self.item(person, account)) }
    }
    /// Reads both formats: bare vectors before 0.9, exemplars with their origin since.
    static func decode(_ data: Data) throws -> [VoiceExemplar] {
        let values: [VoiceExemplar]
        if let legacy = try? JSONDecoder().decode([[Float]].self, from: data) { values = legacy.map { VoiceExemplar(vector: $0) } }
        else { values = try JSONDecoder().decode([VoiceExemplar].self, from: data) }
        for value in values { _ = try normalized(value.vector) }
        return values
    }
    /// Keeps a diverse bounded collection by removing the most redundant exemplar.
    static func pruned(_ values: [VoiceExemplar], limit: Int = exemplarLimit) -> [VoiceExemplar] {
        var values = values
        while values.count > limit {
            let redundancy = values.indices.map { i in values.indices.filter { $0 != i }.map { VoiceResolver.cosine(values[i].vector, values[$0].vector) }.max() ?? 0 }
            values.remove(at: redundancy.enumerated().max(by: { $0.element < $1.element })!.offset)
        }
        return values
    }
    /// Exemplars of one channel. Former near and room samples move to `mic` the first time they are read.
    public func exemplars(person: UUID, channel: VoiceChannel) throws -> [VoiceExemplar] {
        let current = try read(person, channel.rawValue)
        let legacy = try (Self.legacyAccounts[channel] ?? []).flatMap { try read(person, $0) }
        guard !legacy.isEmpty else { return current }
        // A former interrupted migration may have copied some of them already.
        let merged = Self.pruned(current + legacy.filter { old in !current.contains { $0.vector == old.vector } })
        try write(merged, person, channel.rawValue)
        for account in Self.legacyAccounts[channel] ?? [] { try delete(person, account) }
        return merged
    }
    public func vectors(person: UUID, channel: VoiceChannel) throws -> [[Float]] {
        try exemplars(person: person, channel: channel).map(\.vector)
    }
    public static func normalized(_ vector: [Float]) throws -> [Float] {
        guard vector.count == 256, vector.allSatisfy(\.isFinite) else { throw VoiceError.invalidVector }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0.0001 else { throw VoiceError.invalidVector }
        return vector.map { $0 / norm }
    }
    public func add(_ vector: [Float], person: UUID, channel: VoiceChannel, recordingID: UUID? = nil, speakerID: UUID? = nil) throws {
        let values = try exemplars(person: person, channel: channel)
            + [VoiceExemplar(vector: try Self.normalized(vector), recordingID: recordingID, speakerID: speakerID, addedAt: Date())]
        try write(Self.pruned(values), person, channel.rawValue)
    }
    /// What each session added, per channel. No vector leaves this function.
    public func contributions(person: UUID) throws -> [VoiceContribution] {
        try VoiceChannel.allCases.flatMap { channel in Self.contributions(of: try exemplars(person: person, channel: channel), channel: channel) }
    }
    static func contributions(of exemplars: [VoiceExemplar], channel: VoiceChannel) -> [VoiceContribution] {
        Dictionary(grouping: exemplars, by: \.recordingID).map { id, group in
            VoiceContribution(recordingID: id, channel: channel, count: group.count, addedAt: group.compactMap(\.addedAt).max())
        }.sorted { ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
    }
    /// Withdraws what one session added (nil: samples of unknown origin). Returns the channels that still hold samples.
    @discardableResult
    public func remove(person: UUID, recordingID: UUID?) throws -> [VoiceChannel] {
        try VoiceChannel.allCases.filter { channel in
            let kept = try exemplars(person: person, channel: channel).filter { $0.recordingID != recordingID }
            try write(kept, person, channel.rawValue)
            return !kept.isEmpty
        }
    }
    public func remove(person: UUID) throws {
        let accounts = VoiceChannel.allCases.map(\.rawValue) + Self.legacyAccounts.values.flatMap { $0 }
        for account in accounts { try delete(person, account) }
    }
}
public enum VoiceResolver {
    public static let threshold = 0.75
    /// A match through the other channel must clear this instead of `threshold`.
    public static let crossChannelThreshold = 0.85
    public struct Candidate: Equatable, Sendable {
        public var score: Double
        public var channel: VoiceChannel
        public var crossChannel: Bool
        /// Score compared against `threshold`: a cross-channel score pays the difference between the two thresholds.
        public var adjusted: Double { crossChannel ? score - (crossChannelThreshold - threshold) : score }
    }
    /// How well one voice heard on `channel` matches one person. Their exemplars from the same channel
    /// decide when they exist; otherwise the other channel is tried as a last resort.
    public static func candidate(_ vector: [Float], channel: VoiceChannel, exemplars: [VoiceChannel: [[Float]]]) -> Candidate? {
        if let own = exemplars[channel], !own.isEmpty { return Candidate(score: score(vector, exemplars: own), channel: channel, crossChannel: false) }
        if let other = exemplars[channel.other], !other.isEmpty { return Candidate(score: score(vector, exemplars: other), channel: channel.other, crossChannel: true) }
        return nil
    }
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        return Double(zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 })
    }
    public static func score(_ vector: [Float], exemplars: [[Float]]) -> Double {
        let best = exemplars.map { cosine(vector, $0) }.sorted(by: >).prefix(3)
        return best.isEmpty ? -1 : best.reduce(0, +) / Double(best.count)
    }
    /// Hungarian maximum assignment, dummy columns allow every cluster to remain unknown.
    public static func assign(scores: [[Double]], threshold: Double = VoiceResolver.threshold, margin: Double = 0.1) -> [Int?] {
        let n = scores.count; guard n > 0 else { return [] }
        let candidates = scores.first?.count ?? 0
        guard candidates > 0, scores.allSatisfy({ $0.count == candidates }) else { return Array(repeating: nil, count: n) }
        var eligible = Array<Int?>(repeating: nil, count: n)
        for i in 0..<n {
            let ranked = scores[i].enumerated().sorted { $0.element > $1.element }
            if ranked[0].element >= threshold, ranked.count == 1 || ranked[0].element - ranked[1].element >= margin { eligible[i] = ranked[0].offset }
        }
        let m = candidates + n
        var u = [Double](repeating: 0, count: n + 1), v = [Double](repeating: 0, count: m + 1)
        var p = [Int](repeating: 0, count: m + 1), way = p
        for i in 1...n {
            p[0] = i; var j0 = 0
            var minv = [Double](repeating: .infinity, count: m + 1), used = [Bool](repeating: false, count: m + 1)
            repeat {
                used[j0] = true; let i0 = p[j0]; var delta = Double.infinity; var j1 = 0
                for j in 1...m where !used[j] {
                    let value = j <= candidates ? (eligible[i0 - 1] == j - 1 ? scores[i0 - 1][j - 1] : -1) : 0
                    let cur = -value - u[i0] - v[j]
                    if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...m { if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta } }
                j0 = j1
            } while p[j0] != 0
            repeat { let j1 = way[j0]; p[j0] = p[j1]; j0 = j1 } while j0 != 0
        }
        var result = Array<Int?>(repeating: nil, count: n)
        for j in 1...candidates where p[j] > 0 { if eligible[p[j] - 1] == j - 1 { result[p[j] - 1] = j - 1 } }
        return result
    }
}
extension SessionStore {
    public func people() throws -> [VoicePerson] {
        try database.read { db in try Data.fetchAll(db, sql: "SELECT payload FROM voice_people ORDER BY id").map { try JSONDecoder().decode(VoicePerson.self, from: $0) } }
    }
    public func savePerson(_ person: VoicePerson) throws {
        guard !person.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StoreError.invalidName }
        try database.write { db in
            let existing = try Data.fetchAll(db, sql: "SELECT payload FROM voice_people").map { try JSONDecoder().decode(VoicePerson.self, from: $0) }
            if !person.opposed && existing.contains(where: { $0.opposed && ($0.id == person.id || $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == person.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }) { throw VoiceError.consentRequired }
            try db.execute(sql: "UPDATE integration_sequence SET seq=seq+1")
            try db.execute(sql: "INSERT INTO voice_people(id,payload) VALUES (?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", arguments: [person.id.uuidString, try JSONEncoder().encode(person)]) }
    }
    /// Ends an opposition on the user's request. The person comes back with no voice print and no
    /// enrollment request: recognition needs a new, explicit enrollment.
    public func liftOpposition(_ id: UUID) throws {
        try database.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM voice_people WHERE id=?", arguments: [id.uuidString]) else { throw StoreError.notFound }
            var person = try JSONDecoder().decode(VoicePerson.self, from: data)
            person.opposed = false; person.consentedAt = nil; person.enrollmentRequestedAt = nil
            person.enrolledChannels = nil; person.lastEnrolledAt = nil
            try db.execute(sql: "UPDATE integration_sequence SET seq=seq+1")
            try db.execute(sql: "UPDATE voice_people SET payload=? WHERE id=?", arguments: [try JSONEncoder().encode(person), id.uuidString])
        }
    }
}
