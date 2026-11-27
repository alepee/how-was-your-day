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

    /// Every input the capture can record, and the default input when it is one of them. HWYD's
    /// own aggregates are left out, and so is any device the graph would refuse, so that neither a
    /// picker nor a forced switch lands on one: an aggregate (it cannot be nested in the capture's),
    /// more than one input stream, more than 14 channels (the combined graph adds the two of system
    /// audio, up to 16), or a format other than 32-bit float PCM.
    static func microphones() -> MicrophoneList {
        var prop = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &prop, 0, nil, &size) == noErr, size > 0 else { return MicrophoneList() }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &prop, 0, nil, &size, &ids) == noErr else { return MicrophoneList() }
        let devices: [MicrophoneDevice] = ids.compactMap { id in
            guard let uid = try? string(id, kAudioDevicePropertyDeviceUID), !uid.hasPrefix(ownPrefix), isRecordable(id) else { return nil }
            let name = (try? string(id, kAudioObjectPropertyName)) ?? uid
            return MicrophoneDevice(uid: uid, name: name, transport: transport(id))
        }
        let input = defaultInput
        let defaultUID = input == 0 ? nil : try? string(input, kAudioDevicePropertyDeviceUID)
        return MicrophoneList(devices: devices, defaultInput: devices.contains { $0.uid == defaultUID } ? defaultUID : nil)
    }
    /// What `CoreAudioCapture.buildGraph` accepts as a microphone.
    private static func isRecordable(_ device: AudioObjectID) -> Bool {
        guard (try? scalar(device, kAudioDevicePropertyTransportType, as: UInt32.self)) != kAudioDeviceTransportTypeAggregate,
              let inputs = try? streams(device), inputs.count == 1, let format = try? format(inputs[0]) else { return false }
        return format.mFormatID == kAudioFormatLinearPCM && format.mBitsPerChannel == 32 && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && (1...14).contains(format.mChannelsPerFrame)
    }
    private static func transport(_ device: AudioObjectID) -> MicrophoneTransport {
        switch (try? scalar(device, kAudioDevicePropertyTransportType, as: UInt32.self)) ?? 0 {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeVirtual: .virtual
        default: .other
        }
    }

    /// The process objects of every application that has an audio client. Reading them opens nothing.
    static func processObjects() -> [AudioObjectID] {
        var prop = address(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &prop, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &prop, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
    static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        ((try? scalar(object, selector, as: UInt32.self)) ?? 0) != 0
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
/// input, read again once their changes settle. Never opens a device. The HAL is read on a queue
/// of its own, never on the main thread: a read can block while a device is being created, such as
/// the capture's own aggregate during a rebuild. The list is empty until the first read is in.
@MainActor final class CoreAudioMicrophones: MicrophoneCatalog {
    private let subject = CurrentValueSubject<MicrophoneList, Never>(MicrophoneList())
    private let reader = Reader()

    init() {
        reader.start { [weak self] list in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.subject.send(list) } }
        }
    }
    var current: MicrophoneList { subject.value }
    var changes: AnyPublisher<MicrophoneList, Never> { subject.removeDuplicates().eraseToAnyPublisher() }

    /// Reads the HAL on its own queue, 250 ms after the last of a burst of notifications.
    /// Its state is only touched on that queue.
    private final class Reader: @unchecked Sendable {
        private let queue = DispatchQueue(label: "dev.lepee.hwyd.microphones", qos: .utility)
        private var watch: DeviceWatch?
        private var pending: DispatchWorkItem?

        func start(_ deliver: @escaping @Sendable (MicrophoneList) -> Void) {
            queue.async { [weak self] in
                guard let self else { return }
                watch = HAL.watchDevices(on: queue) { [weak self] in self?.schedule(deliver) }
                deliver(HAL.microphones())
            }
        }
        private func schedule(_ deliver: @escaping @Sendable (MicrophoneList) -> Void) {
            pending?.cancel()
            let read = DispatchWorkItem { deliver(HAL.microphones()) }
            pending = read
            queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: read)
        }
    }
}
