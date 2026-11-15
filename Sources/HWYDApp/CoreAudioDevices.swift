import Combine
import CoreAudio
import Foundation
import HWYDCore

/// Reads of the Core Audio hardware: properties, devices, the default input and output. Reading
/// never opens a device. Errors carry a message for the user.
enum HAL {
    /// Prefix of the aggregate devices HWYD creates: they are private, so only this process lists
    /// them, and they are never offered as microphones.
    static let ownPrefix = "dev.lepee.hwyd."
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw CaptureFailure(message: String(localized: "\(operation) impossible (Core Audio \(status)). Vérifiez les permissions audio de HWYD dans Réglages Système.")) }
    }
    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as type: T.Type,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> T {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        var prop = address(selector, scope: scope), size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &prop, 0, nil, &size, pointer), String(localized: "Lecture de la configuration audio"))
        return pointer.load(as: T.self)
    }
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var prop = address(selector), size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        defer { storage.deallocate() }
        storage.storeBytes(of: Optional<UnsafeRawPointer>.none, as: Optional<UnsafeRawPointer>.self)
        try check(AudioObjectGetPropertyData(object, &prop, 0, nil, &size, storage), String(localized: "Lecture du périphérique"))
        guard let pointer = storage.load(as: Optional<UnsafeRawPointer>.self) else { throw CaptureFailure(message: String(localized: "Identifiant audio manquant.")) }
        return Unmanaged<CFString>.fromOpaque(pointer).takeRetainedValue() as String
    }
    static func streams(_ device: AudioObjectID) throws -> [AudioObjectID] {
        var prop = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &prop, 0, nil, &size), String(localized: "Lecture des pistes"))
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(device, &prop, 0, nil, &size, &result), String(localized: "Lecture des pistes"))
        return result
    }
    static func format(_ stream: AudioObjectID) throws -> AudioStreamBasicDescription { try scalar(stream, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self) }

    static var defaultInput: AudioObjectID { (try? scalar(system, kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self)) ?? 0 }
    static var defaultOutput: AudioObjectID { (try? scalar(system, kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)) ?? 0 }

    /// The device with this UID, or 0 when it is not present.
    static func device(uid: String) -> AudioObjectID {
        var prop = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString, device: AudioObjectID = 0, size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { pointer in
            AudioObjectGetPropertyData(system, &prop, UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr ? device : 0
    }
    static func isAlive(_ device: AudioObjectID) -> Bool {
        device != 0 && ((try? scalar(device, kAudioDevicePropertyDeviceIsAlive, as: UInt32.self)) ?? 0) != 0
    }

    /// Every device with an input stream, HWYD's own aggregates left out, and the default input.
    static func microphones() -> MicrophoneList {
        var prop = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &prop, 0, nil, &size) == noErr, size > 0 else { return MicrophoneList() }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &prop, 0, nil, &size, &ids) == noErr else { return MicrophoneList() }
        let devices: [MicrophoneDevice] = ids.compactMap { id in
            guard let uid = try? string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix(ownPrefix),
                  let inputs = try? streams(id), !inputs.isEmpty else { return nil }
            let name = (try? string(id, kAudioObjectPropertyName)) ?? uid
            return MicrophoneDevice(uid: uid, name: name, transport: transport(id))
        }
        let input = defaultInput
        let defaultUID = input == 0 ? nil : try? string(input, kAudioDevicePropertyDeviceUID)
        return MicrophoneList(devices: devices, defaultInput: devices.contains { $0.uid == defaultUID } ? defaultUID : nil)
    }
    private static func transport(_ device: AudioObjectID) -> MicrophoneTransport {
        switch (try? scalar(device, kAudioDevicePropertyTransportType, as: UInt32.self)) ?? 0 {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: .virtual
        default: .other
        }
    }

    /// Calls `changed` on `queue` whenever the devices or the default input or output change.
    /// The returned token removes the listeners.
    static func watchDevices(on queue: DispatchQueue, _ changed: @escaping @Sendable () -> Void) -> DeviceWatch {
        let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice]
        return DeviceWatch(listeners: selectors.map { (system, address($0)) }, queue: queue, changed)
    }
}

/// Property listeners on Core Audio objects, removed with `cancel` or when released.
final class DeviceWatch: @unchecked Sendable {
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress)]
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(listeners: [(AudioObjectID, AudioObjectPropertyAddress)], queue: DispatchQueue, _ changed: @escaping @Sendable () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in changed() }
        self.queue = queue; self.block = block
        self.listeners = listeners.filter { object, address in
            var address = address
            return AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr
        }
    }
    func cancel() {
        for (object, address) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        listeners = []
    }
    deinit { cancel() }
}

/// The inputs before a capture starts, for the setup screen: Core Audio's devices and default
/// input, read again whenever they change. Never opens a device.
@MainActor final class CoreAudioMicrophones: MicrophoneCatalog {
    private let subject = CurrentValueSubject<MicrophoneList, Never>(MicrophoneList())
    private var watch: DeviceWatch?

    init() {
        subject.send(HAL.microphones())
        watch = HAL.watchDevices(on: .main) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    var current: MicrophoneList { subject.value }
    var changes: AnyPublisher<MicrophoneList, Never> { subject.removeDuplicates().eraseToAnyPublisher() }
    private func refresh() { subject.send(HAL.microphones()) }
}
