import Combine
import Foundation

/// How an input device is connected. A Bluetooth headset switches to call mode, at a lower
/// sound quality, once its microphone is used.
public enum MicrophoneTransport: String, Codable, Sendable {
    case builtIn, usb, bluetooth, virtual, other
}

/// An input device the capture can record, identified by its Core Audio UID.
public struct MicrophoneDevice: Identifiable, Hashable, Sendable {
    public var uid: String
    public var name: String
    public var transport: MicrophoneTransport
    public var id: String { uid }
    public init(uid: String, name: String, transport: MicrophoneTransport = .other) {
        self.uid = uid; self.name = name; self.transport = transport
    }
}

/// The input devices present and the system default input.
public struct MicrophoneList: Equatable, Sendable {
    public var devices: [MicrophoneDevice]
    /// UID of the system default input, nil when there is none.
    public var defaultInput: String?
    public init(devices: [MicrophoneDevice] = [], defaultInput: String? = nil) { self.devices = devices; self.defaultInput = defaultInput }

    public func device(_ uid: String?) -> MicrophoneDevice? { uid.flatMap { uid in devices.first { $0.uid == uid } } }
    public var defaultDevice: MicrophoneDevice? { device(defaultInput) }

    /// The microphone a capture starts on: the remembered one when present, otherwise nil, which
    /// stands for the system default input.
    public func choice(remembered uid: String?) -> String? { device(uid)?.uid }

    /// Where the capture goes when the microphone `lost` disappeared: the system default input, or
    /// any input left; nil when none is left.
    public func replacement(for lost: String) -> MicrophoneDevice? {
        if let preferred = defaultDevice, preferred.uid != lost { return preferred }
        return devices.first { $0.uid != lost }
    }
}

/// The input devices, before a capture starts: the setup screen's picker reads them. While a
/// capture runs, `AudioCapture` reports its own list through its events.
///
/// Listing devices never opens one. The app's adapter reads Core Audio; demos, previews and
/// checks get `FixedMicrophones`.
@MainActor public protocol MicrophoneCatalog: AnyObject {
    var current: MicrophoneList { get }
    /// The current list, then each change.
    var changes: AnyPublisher<MicrophoneList, Never> { get }
}

/// A list set by hand: demo mode, previews, snapshots and tests.
@MainActor public final class FixedMicrophones: MicrophoneCatalog {
    private let subject: CurrentValueSubject<MicrophoneList, Never>
    public init(_ list: MicrophoneList = .simulated) { subject = CurrentValueSubject(list) }
    public var current: MicrophoneList { subject.value }
    public var changes: AnyPublisher<MicrophoneList, Never> { subject.eraseToAnyPublisher() }
    public func set(_ list: MicrophoneList) { subject.send(list) }
}

extension MicrophoneList {
    /// Two fictional inputs for demos and previews; no device is opened.
    public static let simulated = MicrophoneList(devices: [
        MicrophoneDevice(uid: "simulated.builtin", name: String(localized: "Micro du Mac", bundle: .hwyd), transport: .builtIn),
        MicrophoneDevice(uid: "simulated.headset", name: String(localized: "Casque Bluetooth", bundle: .hwyd), transport: .bluetooth)
    ], defaultInput: "simulated.builtin")
}

/// Why the capture changed microphone.
public enum MicrophoneSwitchReason: String, Sendable {
    /// The user chose another microphone.
    case user
    /// The user accepted the microphone the system proposed.
    case accepted
    /// The microphone in use disappeared.
    case forced

    var boundary: CaptureBoundaryReason {
        switch self { case .user: .user; case .accepted: .accepted; case .forced: .forced }
    }
}

extension SettingKey where Value == String? {
    /// UID of the last microphone the user chose. Nil until a choice, or the system default input.
    public static var microphone: Self { .init("capture.microphone", default: nil) }
}
