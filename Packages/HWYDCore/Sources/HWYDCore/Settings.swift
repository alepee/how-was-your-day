import Foundation

/// A value a settings store can hold. Stored as a property-list value, so the UserDefaults
/// adapter keeps the format earlier versions wrote.
public protocol SettingValue {
    /// Nil when the stored value is missing or of another type; the key's default applies.
    init?(storedValue: Any)
    /// Nil removes the stored value.
    var storedValue: Any? { get }
}

extension Bool: SettingValue {
    public init?(storedValue: Any) {
        // UserDefaults reads "YES", "true" and "1" as true, and so do these.
        if let value = storedValue as? Bool { self = value }
        else if let text = storedValue as? String { self = ["yes", "true", "1"].contains(text.lowercased()) }
        else { return nil }
    }
    public var storedValue: Any? { self }
}
extension Int: SettingValue {
    public init?(storedValue: Any) {
        if let value = storedValue as? Int { self = value }
        else if let text = storedValue as? String, let value = Int(text) { self = value }
        else { return nil }
    }
    public var storedValue: Any? { self }
}
extension String: SettingValue {
    public init?(storedValue: Any) { guard let value = storedValue as? String else { return nil }; self = value }
    public var storedValue: Any? { self }
}
extension Data: SettingValue {
    public init?(storedValue: Any) { guard let value = storedValue as? Data else { return nil }; self = value }
    public var storedValue: Any? { self }
}
extension Date: SettingValue {
    public init?(storedValue: Any) { guard let value = storedValue as? Date else { return nil }; self = value }
    public var storedValue: Any? { self }
}
extension Array: SettingValue where Element == String {
    public init?(storedValue: Any) { guard let value = storedValue as? [String] else { return nil }; self = value }
    public var storedValue: Any? { self }
}
extension Optional: SettingValue where Wrapped: SettingValue {
    public init?(storedValue: Any) { self = Wrapped(storedValue: storedValue) }
    public var storedValue: Any? { self?.storedValue }
}
/// Enumerations are stored as their raw value. An unknown raw value falls back to the key's default.
extension SettingValue where Self: RawRepresentable, RawValue: SettingValue {
    public init?(storedValue: Any) {
        guard let raw = RawValue(storedValue: storedValue) else { return nil }
        self.init(rawValue: raw)
    }
    public var storedValue: Any? { rawValue.storedValue }
}
extension SessionKind: SettingValue {}
extension SummaryService: SettingValue {}

/// A typed preference: its stored name and the value used when nothing valid is stored.
public struct SettingKey<Value: SettingValue>: Sendable {
    public let name: String
    private let makeDefault: @Sendable () -> Value
    public var defaultValue: Value { makeDefault() }
    public init(_ name: String, default defaultValue: @autoclosure @escaping @Sendable () -> Value) {
        self.name = name; self.makeDefault = defaultValue
    }
}

/// The app's preferences. Each value is read and written through a typed `SettingKey`;
/// every key is declared once, in `SettingKey` below.
public protocol SettingsStore: AnyObject {
    func storedValue(forKey name: String) -> Any?
    /// Nil removes the value.
    func setStoredValue(_ value: Any?, forKey name: String)
}
extension SettingsStore {
    public func value<Value>(_ key: SettingKey<Value>) -> Value {
        storedValue(forKey: key.name).flatMap(Value.init(storedValue:)) ?? key.defaultValue
    }
    /// Whether something is stored under the key, valid or not.
    public func contains<Value>(_ key: SettingKey<Value>) -> Bool { storedValue(forKey: key.name) != nil }
    public func set<Value>(_ value: Value, for key: SettingKey<Value>) { setStoredValue(value.storedValue, forKey: key.name) }
    public func remove<Value>(_ key: SettingKey<Value>) { setStoredValue(nil, forKey: key.name) }
}

/// Preferences of the installed app, in a UserDefaults domain.
public final class UserDefaultsSettings: SettingsStore {
    public let defaults: UserDefaults
    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func storedValue(forKey name: String) -> Any? { defaults.object(forKey: name) }
    public func setStoredValue(_ value: Any?, forKey name: String) {
        if let value { defaults.set(value, forKey: name) } else { defaults.removeObject(forKey: name) }
    }
}

/// Preferences kept in memory only: previews, tests and isolated checks.
public final class InMemorySettings: SettingsStore {
    private var values: [String: Any]
    public init(_ values: [String: Any] = [:]) { self.values = values }
    public func storedValue(forKey name: String) -> Any? { values[name] }
    public func setStoredValue(_ value: Any?, forKey name: String) { values[name] = value }
}

// MARK: Keys
// The names are the UserDefaults keys earlier versions wrote; changing one loses the user's setting.

extension SettingKey where Value == String? {
    /// `AppearancePreference` raw value, read by the app.
    public static var appearance: Self { .init("appearancePreference", default: nil) }
    /// Words that exclude a calendar event from reminders. Nil until the user edits them.
    public static var calendarExclusions: Self { .init("calendar.exclusions", default: nil) }
    /// Model chosen for a hosted provider, one per provider. Nil until chosen.
    public static func summaryHostedModel(_ service: SummaryService) -> Self { .init("summary.model." + service.rawValue, default: nil) }
}
extension SettingKey where Value == Date? {
    /// When the automatic summary was turned on: sessions recorded before are never summarized on their own.
    public static var summaryAutomaticSince: Self { .init("summary.automatic.since", default: nil) }
}
extension SettingKey where Value == SessionKind {
    public static var newSessionKind: Self { .init("newSession.kind", default: .adHoc) }
}
extension SettingKey where Value == Data? {
    /// Encoded `RecordingShortcut`; empty data means the user cleared the shortcut.
    public static var recordingShortcut: Self { .init("shortcut.record", default: nil) }
}
extension SettingKey where Value == Bool {
    public static var diarizationEnabled: Self { .init("diarizationEnabled", default: false) }
    public static var summaryEnabled: Self { .init("summary.enabled", default: false) }
    public static var summaryReasoningDisabled: Self { .init("summary.reasoningDisabled", default: false) }
    /// Starts the summary on its own once a session is ready.
    public static var summaryAutomatic: Self { .init("summary.automatic", default: false) }
    public static var calendarEnabled: Self { .init("calendar.enabled", default: false) }
    public static var calendarReminders: Self { .init("calendar.reminders", default: false) }
}
extension SettingKey where Value == String {
    public static var summaryEndpoint: Self { .init("summary.endpoint", default: "http://127.0.0.1:1234/v1") }
    public static var summaryLocalModel: Self { .init("summary.model", default: "") }
    public static var summaryAgentCommand: Self { .init("summary.agent.command", default: "claude-agent-acp") }
    public static var summaryAgentDirectory: Self { .init("summary.agent.directory", default: "~") }
}
extension SettingKey where Value == SummaryService {
    public static var summaryService: Self { .init("summary.service", default: .local) }
}
extension SettingKey where Value == Int {
    /// Context loaded in the local server. Zero, written by early versions, means the default.
    public static var summaryContextTokens: Self { .init("summary.contextTokens", default: 32768) }
    /// Minutes before a meeting for its reminder.
    public static var calendarLeadMinutes: Self { .init("calendar.lead", default: 5) }
}
extension SettingKey where Value == [String] {
    public static var calendarSelection: Self { .init("calendar.selected", default: []) }
    /// Legacy list of handled occurrences, removed at start.
    public static var calendarHandled: Self { .init("calendar.handled", default: []) }
}

/// Preferences read from another store, changed in memory only: the examples read the user's
/// preferences and never write them, and a check can read a store it must not change.
public final class VolatileSettings: SettingsStore {
    private let base: SettingsStore
    /// Changes made here; `NSNull` marks a removed value.
    private var changes: [String: Any] = [:]
    public init(over base: SettingsStore) { self.base = base }
    public func storedValue(forKey name: String) -> Any? {
        guard let changed = changes[name] else { return base.storedValue(forKey: name) }
        return changed is NSNull ? nil : changed
    }
    public func setStoredValue(_ value: Any?, forKey name: String) { changes[name] = value ?? NSNull() }
}
