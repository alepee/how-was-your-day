import Foundation
import Security
import GRDB

public enum VoiceChannel: String, Codable, CaseIterable, Sendable { case near, room, remote }
public struct VoicePerson: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var consentedAt: Date?
    public var opposed: Bool
    public init(id: UUID = UUID(), name: String, consentedAt: Date? = nil, opposed: Bool = false) {
        self.id = id; self.name = name; self.consentedAt = consentedAt; self.opposed = opposed
    }
}
public struct VoiceMatch: Codable, Equatable, Sendable {
    public var personID: UUID
    public var score: Double
    public var margin: Double?
    public var channel: VoiceChannel
    public init(personID: UUID, score: Double, margin: Double?, channel: VoiceChannel) {
        self.personID = personID; self.score = score; self.margin = margin; self.channel = channel
    }
}
public struct VoiceJob: Codable, Sendable {
    public var recording: Recording
    public var speakerID: UUID?
    public var personID: UUID?
    public var channel: VoiceChannel
    public init(recording: Recording, speakerID: UUID? = nil, personID: UUID? = nil, channel: VoiceChannel) {
        self.recording = recording; self.speakerID = speakerID; self.personID = personID; self.channel = channel
    }
}
public enum VoiceError: LocalizedError {
    case consentRequired, invalidVector, keychain(OSStatus), insufficientSpeech
    public var errorDescription: String? {
        switch self {
        case .consentRequired: "Le consentement vocal explicite est requis et aucune opposition ne doit être active."
        case .invalidVector: "Empreinte vocale invalide."
        case .keychain(let status): "Trousseau indisponible (\(status)). Aucune empreinte exportée."
        case .insufficientSpeech: "Il faut au moins 20 secondes de parole propre pour cette voix, sans chevauchement."
        }
    }
}
/// Vectors never enter SQLite, job files, exports or logs. Helper alone accesses this service.
public enum VoiceKeychain {
    private static let service = "dev.lepee.hwyd.voice.we-speaker-v1"
    private static func query(_ person: UUID, _ channel: VoiceChannel) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: person.uuidString + "." + channel.rawValue,
         kSecAttrSynchronizable as String: false]
    }
    public static func vectors(person: UUID, channel: VoiceChannel) throws -> [[Float]] {
        var q = query(person, channel); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw VoiceError.keychain(status) }
        let vectors = try JSONDecoder().decode([[Float]].self, from: data)
        for vector in vectors { _ = try normalized(vector) }
        return vectors
    }
    public static func normalized(_ vector: [Float]) throws -> [Float] {
        guard vector.count == 256, vector.allSatisfy(\.isFinite) else { throw VoiceError.invalidVector }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0.0001 else { throw VoiceError.invalidVector }
        return vector.map { $0 / norm }
    }
    public static func add(_ vector: [Float], person: UUID, channel: VoiceChannel) throws {
        var values = try vectors(person: person, channel: channel)
        values.append(try normalized(vector))
        // Keep a diverse bounded collection by removing the most redundant exemplar.
        while values.count > 20 {
            let redundancy = values.indices.map { i in values.indices.filter { $0 != i }.map { VoiceResolver.cosine(values[i], values[$0]) }.max() ?? 0 }
            values.remove(at: redundancy.enumerated().max(by: { $0.element < $1.element })!.offset)
        }
        let data = try JSONEncoder().encode(values)
        let q = query(person, channel)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = q; attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let add = SecItemAdd(attributes as CFDictionary, nil)
            guard add == errSecSuccess else { throw VoiceError.keychain(add) }
        } else if status != errSecSuccess { throw VoiceError.keychain(status) }
    }
    public static func remove(person: UUID) throws {
        for channel in VoiceChannel.allCases {
            let status = SecItemDelete(query(person, channel) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw VoiceError.keychain(status) }
        }
    }
}
public enum VoiceResolver {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        return Double(zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 })
    }
    public static func score(_ vector: [Float], exemplars: [[Float]]) -> Double {
        let best = exemplars.map { cosine(vector, $0) }.sorted(by: >).prefix(3)
        return best.isEmpty ? -1 : best.reduce(0, +) / Double(best.count)
    }
    /// Hungarian maximum assignment, dummy columns allow every cluster to remain unknown.
    public static func assign(scores: [[Double]], threshold: Double = 0.75, margin: Double = 0.1) -> [Int?] {
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
}
