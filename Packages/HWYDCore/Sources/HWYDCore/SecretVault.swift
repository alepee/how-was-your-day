import Foundation
import Security
import Synchronization

/// One secret: a service and an account, the way the keychain names a generic password.
public struct SecretItem: Hashable, Sendable {
    public let service: String
    public let account: String
    public init(service: String, account: String) { self.service = service; self.account = account }
}

/// A store the vault could not use, with its status (an `OSStatus` for the keychain).
public struct SecretVaultFailure: Error, Equatable, Sendable {
    public let status: Int32
    public init(status: Int32) { self.status = status }
}

/// Where secrets live: summary API keys and voice prints. The installed app and `hwyd-pipeline`
/// use the keychain; tests, previews, examples and synthetic checks get `InMemorySecretVault`, so
/// they never reach the user's keychain. Nothing read from a vault goes to SQLite, exports, job
/// files or logs.
public protocol SecretVault: Sendable {
    /// The secret's data; nil when there is none.
    func read(_ item: SecretItem) throws -> Data?
    /// Whether the secret exists, without reading it.
    func contains(_ item: SecretItem) -> Bool
    /// Creates or replaces the secret.
    func write(_ data: Data, for item: SecretItem) throws
    /// Removes the secret; a missing one is not an error.
    func remove(_ item: SecretItem) throws
}

/// The login keychain: one generic password per item, never synchronized, readable only while
/// this Mac is unlocked. These attributes are the ones every version wrote, so existing keys and
/// voice prints still resolve.
public struct KeychainVault: SecretVault {
    public init() {}
    private func query(_ item: SecretItem) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: item.service,
         kSecAttrAccount as String: item.account, kSecAttrSynchronizable as String: false]
    }
    public func read(_ item: SecretItem) throws -> Data? {
        var q = query(item); q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecretVaultFailure(status: status) }
        return data
    }
    public func contains(_ item: SecretItem) -> Bool {
        var q = query(item); q[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    public func write(_ data: Data, for item: SecretItem) throws {
        let q = query(item)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = q; attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let add = SecItemAdd(attributes as CFDictionary, nil)
            guard add == errSecSuccess else { throw SecretVaultFailure(status: add) }
        } else if status != errSecSuccess { throw SecretVaultFailure(status: status) }
    }
    public func remove(_ item: SecretItem) throws {
        let status = SecItemDelete(query(item) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretVaultFailure(status: status) }
    }
}

/// Secrets kept in this process's memory, lost when it ends. For tests, previews, the examples
/// and the synthetic checks.
public final class InMemorySecretVault: SecretVault {
    private let items: Mutex<[SecretItem: Data]>
    public init(_ items: [SecretItem: Data] = [:]) { self.items = Mutex(items) }
    public func read(_ item: SecretItem) throws -> Data? { items.withLock { $0[item] } }
    public func contains(_ item: SecretItem) -> Bool { items.withLock { $0[item] != nil } }
    public func write(_ data: Data, for item: SecretItem) throws { items.withLock { $0[item] = data } }
    public func remove(_ item: SecretItem) throws { _ = items.withLock { $0.removeValue(forKey: item) } }
    /// Every item held, for tests.
    public var stored: Set<SecretItem> { items.withLock { Set($0.keys) } }
}

/// API keys of the hosted summary providers, one item per provider in the
/// `dev.lepee.hwyd.summary-api-key` service.
public struct SummaryKeys: Sendable {
    public static let service = "dev.lepee.hwyd.summary-api-key"
    public let vault: any SecretVault
    public init(vault: any SecretVault) { self.vault = vault }

    public struct Failure: LocalizedError {
        public let status: OSStatus
        public var errorDescription: String? { String(localized: "Trousseau inaccessible (\(status)).", bundle: .hwyd) }
    }
    public static func item(_ provider: SummaryService) -> SecretItem { SecretItem(service: service, account: provider.rawValue) }

    public func key(for provider: SummaryService) throws -> String? {
        try mapped { try vault.read(Self.item(provider)).flatMap { String(data: $0, encoding: .utf8) } }
    }
    public func hasKey(for provider: SummaryService) -> Bool { vault.contains(Self.item(provider)) }
    public func setKey(_ key: String, for provider: SummaryService) throws {
        try mapped { try vault.write(Data(key.trimmingCharacters(in: .whitespacesAndNewlines).utf8), for: Self.item(provider)) }
    }
    public func removeKey(for provider: SummaryService) throws { try mapped { try vault.remove(Self.item(provider)) } }

    private func mapped<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let failure as SecretVaultFailure { throw Failure(status: failure.status) }
    }
}
