import AVFoundation
import CoreAudio
import Foundation
import HWYDCore
import HWYDRealtime

struct CaptureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
@MainActor final class CaptureController {
    private(set) var finalizationError: String?
    private var tap: AudioObjectID = 0
    /// Microphone plus tap on one clock, or the tap alone when the microphone runs on its own clock.
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var ring: OpaquePointer?
    /// Split mode only: the microphone device runs its own IOProc into its own ring.
    private var micProc: AudioDeviceIOProcID?
    private var micRing: OpaquePointer?
    private var writer: AudioWriter?
    private var lockFD: Int32 = -1
    private var initialInput: AudioObjectID = 0
    private var initialOutput: AudioObjectID = 0
    /// Paused: the devices are stopped, so neither the microphone nor system audio is captured.
    private(set) var isPaused = false
    var micLevel: Float { writer?.status().mic ?? 0 }
    var systemLevel: Float { writer?.status().system ?? 0 }
    var failure: String? {
        if let status = writer?.status() {
            if let error = status.error { return error }
            if !isPaused, let lastPacket = status.lastPacket, ProcessInfo.processInfo.systemUptime - lastPacket > 3 {
                return String(localized: "Le périphérique ne fournit plus de données audio. La session a été arrêtée.")
            }
        }
        if aggregate != 0 {
            if (try? scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self)) != initialInput || (try? scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)) != initialOutput {
                return String(localized: "La route audio a changé. La session a été arrêtée pour préserver les pistes. Relancez une session avec le nouveau périphérique.")
            }
        }
        return nil
    }
    func start(id: UUID, directory: URL) async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw CaptureFailure(message: String(localized: "L’accès au micro est refusé. Autorisez HWYD dans Réglages Système > Confidentialité et sécurité > Microphone.")) }
        lockFD = open(directory.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD); lockFD = -1 }
            throw CaptureFailure(message: String(localized: "Une autre instance de HWYD enregistre déjà une session."))
        }
        do {
            initialInput = try scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self)
            initialOutput = try scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)
            guard initialInput != 0 else { throw CaptureFailure(message: String(localized: "Aucun microphone disponible.")) }
            let inputUID = try string(initialInput, kAudioDevicePropertyDeviceUID)
            let micName = (try? string(initialInput, kAudioObjectPropertyName)) ?? String(localized: "le micro")
            let micStreams = try streams(initialInput)
            guard micStreams.count == 1 else { throw CaptureFailure(message: String(localized: "Ce prototype prend en charge les microphones à un seul flux d’entrée. Sélectionnez le micro du Mac.")) }
            let micFormat = try format(micStreams[0])
            let micChannels = micFormat.mChannelsPerFrame
            var processAddress = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var pid = getpid(), process: AudioObjectID = 0, size = UInt32(MemoryLayout<AudioObjectID>.size)
            let processResult = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &processAddress, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process)
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: processResult == noErr && process != 0 ? [process] : [])
            description.name = "HWYD System Audio"; description.isPrivate = true; description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), String(localized: "Création du tap audio système"))
            let tapRate = try scalar(tap, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self).mSampleRate
            let inputs: [CaptureInput]
            if micFormat.mSampleRate == tapRate {
                let composition: [String: Any] = [
                    kAudioAggregateDeviceNameKey: "HWYD Capture",
                    kAudioAggregateDeviceUIDKey: "dev.lepee.hwyd.capture.\(id.uuidString)",
                    kAudioAggregateDeviceIsPrivateKey: true,
                    kAudioAggregateDeviceIsStackedKey: false,
                    kAudioAggregateDeviceMainSubDeviceKey: inputUID,
                    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: inputUID]],
                    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
                    // Do not wait for a tapped app to play: room conversations must start immediately.
                    kAudioAggregateDeviceTapAutoStartKey: false
                ]
                try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), String(localized: "Création du périphérique agrégé"))
                let aggregateStreams = try streams(aggregate)
                guard aggregateStreams.count == 2 else { throw CaptureFailure(message: String(localized: "Le graphe audio n’expose pas les deux flux attendus. La capture est annulée, sans piste partielle.")) }
                let formats = try aggregateStreams.map { try format($0) }
                // The explicitly ordered subdevice list precedes the tap. Verify its stream layout.
                let starts = try aggregateStreams.map { try scalar($0, kAudioStreamPropertyStartingChannel, as: UInt32.self) }
                try validateLayout(starts: starts, formats: formats, micChannels: micChannels, micName: micName)
                guard let created = HWYDRingCreate(micChannels + 2) else { throw CaptureFailure(message: String(localized: "Mémoire insuffisante pour préparer la capture.")) }
                ring = created
                inputs = [CaptureInput(ring: created, channels: Int(micChannels + 2), sampleRate: formats[0].mSampleRate, layout: .combined(micChannels: Int(micChannels)))]
            } else {
                // A Bluetooth headset in call mode (HFP) runs its microphone at 16 or 24 kHz while system audio stays at 48 kHz.
                // An aggregate only offers the rates its subdevice supports and does not resample, so each source keeps
                // its own device clock. The writer aligns both tracks on host time and compensates their drift.
                let composition: [String: Any] = [
                    kAudioAggregateDeviceNameKey: "HWYD System Capture",
                    kAudioAggregateDeviceUIDKey: "dev.lepee.hwyd.system.\(id.uuidString)",
                    kAudioAggregateDeviceIsPrivateKey: true,
                    kAudioAggregateDeviceIsStackedKey: false,
                    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: false]],
                    kAudioAggregateDeviceTapAutoStartKey: false
                ]
                try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), String(localized: "Création du périphérique agrégé"))
                let systemStreams = try streams(aggregate)
                guard systemStreams.count == 1 else { throw CaptureFailure(message: String(localized: "Le graphe audio n’expose pas le flux système attendu (\(systemStreams.count) flux). La capture est annulée, sans piste partielle.")) }
                let systemFormat = try format(systemStreams[0])
                try validateSplitLayout(mic: micFormat, system: systemFormat, micName: micName)
                guard let systemRing = HWYDRingCreate(2) else { throw CaptureFailure(message: String(localized: "Mémoire insuffisante pour préparer la capture.")) }
                ring = systemRing
                guard let createdMicRing = HWYDRingCreate(micChannels) else { throw CaptureFailure(message: String(localized: "Mémoire insuffisante pour préparer la capture.")) }
                micRing = createdMicRing
                inputs = [
                    CaptureInput(ring: createdMicRing, channels: Int(micChannels), sampleRate: micFormat.mSampleRate, layout: .mic),
                    CaptureInput(ring: systemRing, channels: 2, sampleRate: systemFormat.mSampleRate, layout: .system)
                ]
            }
            writer = try AudioWriter(inputs: inputs, id: id, directory: directory)
            // Drain before the devices start: starting a tap aggregate can block for about a second.
            writer?.start()
            try check(AudioDeviceCreateIOProcID(aggregate, HWYDIOProc, UnsafeMutableRawPointer(ring), &ioProc), String(localized: "Préparation de la capture"))
            if let micRing { try check(AudioDeviceCreateIOProcID(initialInput, HWYDIOProc, UnsafeMutableRawPointer(micRing), &micProc), String(localized: "Préparation du micro")) }
            try check(AudioDeviceStart(aggregate, ioProc), String(localized: "Démarrage de la capture"))
            if let micProc { try check(AudioDeviceStart(initialInput, micProc), String(localized: "Démarrage du micro")) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while writer?.status().lastPacket == nil {
                if let error = writer?.status().error { throw CaptureFailure(message: error) }
                guard ContinuousClock.now < deadline else {
                    throw CaptureFailure(message: String(localized: "Le périphérique audio a démarré mais aucun buffer n’est reçu. Vérifiez les permissions micro et audio système, puis réessayez."))
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch { _ = stop(); throw error }
    }
    /// Stops the devices without ending the session. Buffered audio is written first.
    /// The audio timeline skips the pause: chunks continue where the last frame ended.
    func pause() {
        guard !isPaused, let ioProc, aggregate != 0 else { return }
        AudioDeviceStop(aggregate, ioProc)
        if let micProc { AudioDeviceStop(initialInput, micProc) }
        writer?.pause()
        isPaused = true
    }
    func resume() throws {
        guard isPaused, let ioProc, aggregate != 0 else { return }
        writer?.resume()
        try check(AudioDeviceStart(aggregate, ioProc), String(localized: "Reprise de la capture"))
        if let micProc { try check(AudioDeviceStart(initialInput, micProc), String(localized: "Reprise du micro")) }
        isPaused = false
    }
    func stop() -> [AudioChunk] {
        if let ioProc, aggregate != 0 { AudioDeviceStop(aggregate, ioProc); AudioDeviceDestroyIOProcID(aggregate, ioProc) }
        if let micProc { AudioDeviceStop(initialInput, micProc); AudioDeviceDestroyIOProcID(initialInput, micProc) }
        ioProc = nil; micProc = nil
        let chunks = writer?.finish() ?? []
        finalizationError = writer?.status().error
        writer = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        if let ring { HWYDRingDestroy(ring); self.ring = nil }
        if let micRing { HWYDRingDestroy(micRing); self.micRing = nil }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
        return chunks
    }
    /// Each check reports what it read, so a failure on another Mac can be diagnosed from the message alone.
    /// The ring buffer and the writer assume one interleaved frame and one sample rate for every track.
    private func validateLayout(starts: [UInt32], formats: [AudioStreamBasicDescription], micChannels: UInt32, micName: String) throws {
        guard micChannels + 2 <= 16 else {
            throw CaptureFailure(message: String(localized: "\(micName) expose \(micChannels) canaux, au-delà des 16 canaux pris en charge. Aucun enregistrement n’a démarré."))
        }
        // The IOProc concatenates buffers in stream order, so only the order matters. Channel numbers may leave a gap:
        // a subdevice with outputs (Komplete Audio 6: 6 in, 6 out) puts the tap at 13 instead of 7.
        guard starts.count == 2, starts[0] == 1, starts[1] > micChannels else {
            throw CaptureFailure(message: String(localized: "Ordre des pistes inattendu : canaux de départ \(starts.map(String.init).joined(separator: ", ")), le micro (1) doit précéder l’audio système (\(micChannels + 1) ou plus). Aucun enregistrement n’a démarré."))
        }
        guard formats[0].mChannelsPerFrame == micChannels else {
            throw CaptureFailure(message: String(localized: "\(micName) expose \(formats[0].mChannelsPerFrame) canaux dans le graphe audio, \(micChannels) attendus. Aucun enregistrement n’a démarré."))
        }
        guard formats[1].mChannelsPerFrame == 2 else {
            throw CaptureFailure(message: String(localized: "L’audio système expose \(formats[1].mChannelsPerFrame) canaux, 2 attendus. Aucun enregistrement n’a démarré."))
        }
        try requireFloat32(micName, formats[0]); try requireFloat32(String(localized: "L’audio système"), formats[1])
        guard formats[0].mSampleRate == formats[1].mSampleRate else {
            throw CaptureFailure(message: String(localized: "Fréquences différentes : \(micName) à \(hertz(formats[0].mSampleRate)), audio système à \(hertz(formats[1].mSampleRate)). Aucun enregistrement n’a démarré. Choisissez un autre micro ou alignez les fréquences dans Configuration audio et MIDI."))
        }
    }
    private func validateSplitLayout(mic: AudioStreamBasicDescription, system: AudioStreamBasicDescription, micName: String) throws {
        guard mic.mChannelsPerFrame >= 1, mic.mChannelsPerFrame <= 16 else {
            throw CaptureFailure(message: String(localized: "\(micName) expose \(mic.mChannelsPerFrame) canaux, entre 1 et 16 pris en charge. Aucun enregistrement n’a démarré."))
        }
        guard system.mChannelsPerFrame == 2 else {
            throw CaptureFailure(message: String(localized: "L’audio système expose \(system.mChannelsPerFrame) canaux, 2 attendus. Aucun enregistrement n’a démarré."))
        }
        try requireFloat32(micName, mic); try requireFloat32(String(localized: "L’audio système"), system)
    }
    private func requireFloat32(_ label: String, _ format: AudioStreamBasicDescription) throws {
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw CaptureFailure(message: String(localized: "\(label) fournit un format non pris en charge (\(fourCC(format.mFormatID)), \(format.mBitsPerChannel) bits), PCM flottant 32 bits attendu. Aucun enregistrement n’a démarré."))
        }
    }
    private func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return bytes.allSatisfy({ (0x20...0x7E).contains($0) }) ? String(decoding: bytes, as: UTF8.self) : String(code)
    }
    private func hertz(_ rate: Float64) -> String { rate.rounded() == rate ? "\(Int(rate)) Hz" : "\(rate) Hz" }
    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw CaptureFailure(message: String(localized: "\(operation) impossible (Core Audio \(status)). Vérifiez les permissions audio de HWYD dans Réglages Système.")) }
    }
    private func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as type: T.Type) throws -> T {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        var prop = address(selector), size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &prop, 0, nil, &size, pointer), String(localized: "Lecture de la configuration audio"))
        return pointer.load(as: T.self)
    }
    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var prop = address(selector), size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        defer { storage.deallocate() }
        storage.storeBytes(of: Optional<UnsafeRawPointer>.none, as: Optional<UnsafeRawPointer>.self)
        try check(AudioObjectGetPropertyData(object, &prop, 0, nil, &size, storage), String(localized: "Lecture du périphérique"))
        guard let pointer = storage.load(as: Optional<UnsafeRawPointer>.self) else { throw CaptureFailure(message: String(localized: "Identifiant audio manquant.")) }
        return Unmanaged<CFString>.fromOpaque(pointer).takeRetainedValue() as String
    }
    private func streams(_ device: AudioObjectID) throws -> [AudioObjectID] {
        var prop = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &prop, 0, nil, &size), String(localized: "Lecture des pistes"))
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(device, &prop, 0, nil, &size, &result), String(localized: "Lecture des pistes"))
        return result
    }
    private func format(_ stream: AudioObjectID) throws -> AudioStreamBasicDescription { try scalar(stream, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self) }
}

/// One ring read by the writer. A combined input carries the microphone channels followed by the stereo tap on one
/// device clock. A split input carries one track on its own device clock.
struct CaptureInput: @unchecked Sendable {
    enum Layout { case combined(micChannels: Int), mic, system }
    let ring: OpaquePointer
    let channels: Int
    let sampleRate: Double
    let layout: Layout
}

/// Host-time bookkeeping of one track in split mode, at the 16 kHz output rate.
private struct TrackClock {
    var firstHost: UInt64?
    var leadToDrop: Int64 = 0
    var kept: Int64 = 0
    var measurements = 0
    var baseline = 0.0
    var error = 0.0
}

/// The writer and AVAudioFile instances are confined to one serial queue.
/// Only the status snapshot crosses queues, protected by statusLock.
private final class AudioWriter: @unchecked Sendable {
    static let outputRate = 16000.0
    /// Calibration window, then the residual offset tolerated before one sample is dropped or repeated.
    private static let calibrationBuffers = 50
    private static let toleranceSamples = 32.0
    private let queue = DispatchQueue(label: "dev.lepee.hwyd.audio-writer", qos: .userInitiated)
    private let statusLock = NSLock()
    private var state: (mic: Float, system: Float, error: String?, lastPackets: [Double?]) = (0, 0, nil, [nil, nil])
    private let inputs: [CaptureInput]
    private let split: Bool
    private let directory: URL
    private let relativeDirectory: String
    private let buffers: [UnsafeMutablePointer<Float>]
    private let outputFormat: AVAudioFormat
    private let inputFormats: [AVAudioFormat]
    private let converters: [AVAudioConverter]
    private let ticksPerSecond: Double
    private var pending: [[Float]] = [[], []]
    private var clocks = [TrackClock(), TrackClock()]
    private var origin: UInt64?
    private var files: [AVAudioFile] = []
    private var timer: DispatchSourceTimer?
    private var chunks: [AudioChunk] = []
    private var outputFrames: Int64 = 0
    private var chunkFrames: Int64 = 0
    private var sequence = 0
    private let chunkLimit: Int64
    private var firstHostTime: UInt64?
    /// Measured in split mode: the largest correction applied to a track, in samples. Read by tests.
    private(set) var corrections: [Int64] = [0, 0]
    init(inputs: [CaptureInput], id: UUID, directory: URL, chunkSeconds: Double = 300) throws {
        chunkLimit = Int64(chunkSeconds * Self.outputRate)
        self.inputs = inputs
        split = inputs.count == 2
        relativeDirectory = "audio/\(id.uuidString.lowercased())"
        self.directory = directory.appendingPathComponent(relativeDirectory)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        buffers = inputs.map { .allocate(capacity: 4096 * $0.channels) }
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: Self.outputRate, channels: 1)!
        // Track 0 is the microphone, track 1 system audio, whatever input carries them.
        let rates = split ? [inputs[0].sampleRate, inputs[1].sampleRate] : [inputs[0].sampleRate, inputs[0].sampleRate]
        inputFormats = rates.map { AVAudioFormat(standardFormatWithSampleRate: $0, channels: 1)! }
        converters = inputFormats.map { AVAudioConverter(from: $0, to: AVAudioFormat(standardFormatWithSampleRate: Self.outputRate, channels: 1)!)! }
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
    }
    deinit { buffers.forEach { $0.deallocate() } }
    func status() -> (mic: Float, system: Float, error: String?, lastPacket: Double?) {
        statusLock.lock(); defer { statusLock.unlock() }
        // Both tracks must flow: one silent device clock would otherwise stall the other track unnoticed.
        let packets = state.lastPackets.compactMap { $0 }
        return (state.mic, state.system, state.error, packets.count == 2 ? packets.min() : nil)
    }
    func start() {
        queue.sync {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(40))
            source.setEventHandler { [weak self] in self?.drain() }
            timer = source; source.resume()
        }
    }
    func finish() -> [AudioChunk] {
        queue.sync {
            timer?.cancel(); timer = nil
            drain()
            do { try seal() } catch { setError(error.localizedDescription) }
            return chunks
        }
    }
    /// Called after the devices stopped: writes what the rings still hold and silences the meters.
    /// In split mode both clocks are anchored again on resume, so the samples one track holds beyond the other are dropped.
    func pause() {
        queue.sync {
            drain()
            if split {
                pending = [[], []]
                clocks = [TrackClock(), TrackClock()]
                origin = nil
            }
            statusLock.lock(); state.mic = 0; state.system = 0; statusLock.unlock()
        }
    }
    /// Restarts the stall watchdog so the devices have time to deliver their first buffer.
    func resume() {
        statusLock.lock(); let now = ProcessInfo.processInfo.systemUptime; state.lastPackets = [now, now]; statusLock.unlock()
    }
    func consumeForTest() { queue.sync { drain() } }
    private func setError(_ message: String) { statusLock.lock(); state.error = message; statusLock.unlock() }
    private func drain() {
        guard status().error == nil else { return }
        for input in inputs where HWYDRingDropped(input.ring) > 0 {
            let reasons = (0..<4).map { String(HWYDRingDropReason(input.ring, UInt32($0))) }.joined(separator: "/")
            setError(String(localized: "La capture a perdu des buffers audio (\(reasons)). La session est arrêtée pour éviter une désynchronisation silencieuse.")); return
        }
        do {
            for (index, input) in inputs.enumerated() {
                var host: UInt64 = 0
                while true {
                    let frames = HWYDRingRead(input.ring, buffers[index], &host)
                    if frames == 0 { break }
                    if firstHostTime == nil, !split { firstHostTime = host }
                    for track in tracks(of: input) {
                        let peak = try append(track: track, input: input, samples: buffers[index], frames: Int(frames), host: host)
                        statusLock.lock()
                        if track == 0 { state.mic = peak } else { state.system = peak }
                        state.lastPackets[track] = ProcessInfo.processInfo.systemUptime
                        statusLock.unlock()
                    }
                }
            }
            try flush()
            if !split, pending[0].count != pending[1].count { throw CaptureFailure(message: String(localized: "Les deux pistes audio ne sont plus synchronisées.")) }
        } catch { setError(String(localized: "Écriture audio interrompue : \(error.localizedDescription)")) }
    }
    private func tracks(of input: CaptureInput) -> [Int] {
        switch input.layout { case .combined: [0, 1]; case .mic: [0]; case .system: [1] }
    }
    /// Converts one buffer of one track to 16 kHz mono and queues it. Returns the meter level.
    private func append(track: Int, input: CaptureInput, samples: UnsafeMutablePointer<Float>, frames: Int, host: UInt64) throws -> Float {
        let mono = AVAudioPCMBuffer(pcmFormat: inputFormats[track], frameCapacity: AVAudioFrameCount(frames))!
        mono.frameLength = AVAudioFrameCount(frames)
        let pointer = mono.floatChannelData![0]
        let channels = input.channels
        // The microphone keeps its first channel; the stereo tap is averaged.
        let systemOffset: Int = if case .combined(let micChannels) = input.layout { micChannels } else { 0 }
        var peak: Float = 0
        for f in 0..<frames {
            let value = track == 0 ? samples[f * channels] : (samples[f * channels + systemOffset] + samples[f * channels + systemOffset + 1]) * 0.5
            pointer[f] = value; peak = max(peak, abs(value))
        }
        let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(frames) * Self.outputRate / input.sampleRate)) + 64)!
        var supplied = false, error: NSError?
        let result = converters[track].convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return mono
        }
        if result == .error { throw error ?? CaptureFailure(message: String(localized: "Conversion audio impossible.")) as NSError }
        var converted = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        if split { align(track: track, samples: &converted, host: host, duration: Double(frames) / input.sampleRate) }
        pending[track] += converted
        return min(1, peak * 3)
    }
    /// Split mode: both tracks start at the later first buffer, then each one follows host time.
    /// The offset measured over the first buffers absorbs the converter latency; beyond it,
    /// one sample per buffer is dropped or repeated, which stays inaudible and far above clock drift.
    private func align(track: Int, samples: inout [Float], host: UInt64, duration: Double) {
        if clocks[track].firstHost == nil { clocks[track].firstHost = host }
        if origin == nil, let mic = clocks[0].firstHost, let system = clocks[1].firstHost {
            let start = max(mic, system)
            origin = start
            if firstHostTime == nil { firstHostTime = start }
            for index in 0..<2 {
                let lead = Int64((Double(start - clocks[index].firstHost!) / ticksPerSecond * Self.outputRate).rounded())
                let dropped = min(lead, Int64(pending[index].count))
                pending[index].removeFirst(Int(dropped))
                clocks[index].leadToDrop = lead - dropped
                clocks[index].kept = Int64(pending[index].count)
            }
        }
        guard let origin else { return }
        if clocks[track].leadToDrop > 0 {
            let dropped = min(clocks[track].leadToDrop, Int64(samples.count))
            samples.removeFirst(Int(dropped)); clocks[track].leadToDrop -= dropped
        }
        // A buffer that starts before the origin only keeps its frames after it; measure from the next one.
        guard host >= origin, !samples.isEmpty else { clocks[track].kept += Int64(samples.count); return }
        let expected = (Double(host - origin) / ticksPerSecond + duration) * Self.outputRate
        let offset = Double(clocks[track].kept + Int64(samples.count)) - expected
        var clock = clocks[track]
        if clock.measurements < Self.calibrationBuffers {
            clock.baseline += (offset - clock.baseline) / Double(clock.measurements + 1)
        } else {
            clock.error += (offset - clock.baseline - clock.error) * 0.02
            if clock.error > Self.toleranceSamples { samples.removeLast(); clock.error -= 1; corrections[track] += 1 }
            else if clock.error < -Self.toleranceSamples { samples.append(samples[samples.count - 1]); clock.error += 1; corrections[track] += 1 }
        }
        clock.measurements += 1
        clock.kept += Int64(samples.count)
        clocks[track] = clock
    }
    /// Writes the samples both tracks hold, so chunks keep identical bounds.
    private func flush() throws {
        let available = min(pending[0].count, pending[1].count)
        var offset = 0
        while offset < available {
            if files.isEmpty { try openFiles() }
            let count = min(available - offset, Int(chunkLimit - chunkFrames))
            for i in 0..<2 {
                let slice = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(count))!
                slice.frameLength = AVAudioFrameCount(count)
                pending[i].withUnsafeBufferPointer { slice.floatChannelData![0].update(from: $0.baseAddress!.advanced(by: offset), count: count) }
                try files[i].write(from: slice)
            }
            offset += count; chunkFrames += Int64(count); outputFrames += Int64(count)
            if chunkFrames == chunkLimit { try seal(); sequence += 1 }
        }
        if available > 0 { pending[0].removeFirst(available); pending[1].removeFirst(available) }
    }
    private func openFiles() throws {
        let descriptor: [String: String] = ["sample_rate": "16000", "channels": "1", "start_frames": "\(outputFrames)", "host_time": "\(firstHostTime ?? 0)", "sequence": "\(sequence)"]
        try JSONEncoder().encode(descriptor).write(to: directory.appendingPathComponent(String(format: "%06d.json", sequence)), options: .atomic)
        files = try ["mic", "system"].map { source in
            try AVAudioFile(forWriting: directory.appendingPathComponent(String(format: "%@-%06d.partial.caf", source, sequence)), settings: outputFormat.settings)
        }
    }
    private func seal() throws {
        guard !files.isEmpty else { return }
        files.removeAll()
        for source in [AudioSource.mic, .system] {
            let name = String(format: "%@-%06d.caf", source.rawValue, sequence)
            let temporary = directory.appendingPathComponent(String(format: "%@-%06d.partial.caf", source.rawValue, sequence))
            let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
            try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent(name))
            chunks.append(.init(source: source, relativePath: relativeDirectory + "/" + name, start: Double(outputFrames - chunkFrames) / Self.outputRate, duration: Double(chunkFrames) / Self.outputRate))
        }
        try JSONEncoder().encode(chunks).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        chunkFrames = 0
    }
}


extension CaptureController {
    static func verifySyntheticCapture(directory: URL, seconds: Double = 2) throws {
        let id = UUID()
        guard let ring = HWYDRingCreate(3) else { throw CaptureFailure(message: "Ring allocation") }
        defer { HWYDRingDestroy(ring) }
        let writer = try AudioWriter(inputs: [CaptureInput(ring: ring, channels: 3, sampleRate: 48000, layout: .combined(micChannels: 1))], id: id, directory: directory, chunkSeconds: seconds > 10 ? 300 : 0.5)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: 480 * 3)
        defer { samples.deallocate() }
        for i in 0..<480 { samples[i * 3] = 0.2; samples[i * 3 + 1] = 0.6; samples[i * 3 + 2] = 0.6 }
        var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 3, mDataByteSize: UInt32(480 * 3 * 4), mData: samples))
        var time = AudioTimeStamp()
        for block in 0..<Int(seconds * 100) {
            time.mHostTime = UInt64(block * 10_000_000)
            var inputTime = time, outputTime = time
            withUnsafeMutablePointer(to: &input) { pointer in
                _ = HWYDIOProc(0, &time, pointer, &inputTime, pointer, &outputTime, UnsafeMutableRawPointer(ring))
            }
            writer.consumeForTest()
            // A pause mid-capture must not drop, duplicate or desynchronize frames.
            if block == Int(seconds * 50) { writer.pause(); writer.resume() }
        }
        let chunks = writer.finish()
        guard writer.status().error == nil, HWYDRingDropped(ring) == 0, chunks.count >= (seconds > 10 ? 2 : 6) else { throw CaptureFailure(message: "Synthetic capture failed: \(writer.status().error ?? "missing chunks")") }
        for source in [AudioSource.mic, .system] {
            let track = chunks.filter { $0.source == source }
            guard track.reduce(0, { $0 + $1.duration }) > seconds - 0.1 else { throw CaptureFailure(message: "Synthetic duration") }
            for chunk in track {
                let file = try AVAudioFile(forReading: directory.appendingPathComponent(chunk.relativePath))
                guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1, file.length > 0 else { throw CaptureFailure(message: "Invalid CAF format") }
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 64)!
                file.framePosition = file.length / 2
                try file.read(into: buffer)
                let middle = buffer.floatChannelData![0][Int(buffer.frameLength) / 2]
                let expected: Float = source == .mic ? 0.2 : 0.6
                guard abs(middle - expected) < 0.015 else { throw CaptureFailure(message: "Channels mixed: \(middle), expected \(expected)") }
            }
        }
    }

    /// Split mode: a 16 kHz microphone and a 48 kHz tap on two clocks, the tap starting 250 ms later and drifting
    /// by 1000 ppm. A click played on both at the same host time must land on the same output sample, within 3 ms.
    static func verifySyntheticSplitCapture(directory: URL, seconds: Double = 30) throws {
        guard let micRing = HWYDRingCreate(1), let systemRing = HWYDRingCreate(2) else { throw CaptureFailure(message: "Ring allocation") }
        defer { HWYDRingDestroy(micRing); HWYDRingDestroy(systemRing) }
        let writer = try AudioWriter(inputs: [
            CaptureInput(ring: micRing, channels: 1, sampleRate: 16000, layout: .mic),
            CaptureInput(ring: systemRing, channels: 2, sampleRate: 48000, layout: .system)
        ], id: UUID(), directory: directory, chunkSeconds: 300)
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let ticks = 1e9 * Double(timebase.denom) / Double(timebase.numer)
        let micFrames = 320, systemFrames = 512, skew = 1000e-6, systemStart = 0.25, click = seconds * 2 / 3
        let micSamples = UnsafeMutablePointer<Float>.allocate(capacity: micFrames); defer { micSamples.deallocate() }
        let systemSamples = UnsafeMutablePointer<Float>.allocate(capacity: systemFrames * 2); defer { systemSamples.deallocate() }
        var micBlock = 0, systemBlock = 0
        func push(_ ring: OpaquePointer, _ samples: UnsafeMutablePointer<Float>, channels: Int, frames: Int, at time: Double) {
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(frames * channels * 4), mData: samples))
            var stamp = AudioTimeStamp(); stamp.mHostTime = UInt64(1_000_000 + time * ticks)
            var input = stamp, output = stamp
            _ = withUnsafeMutablePointer(to: &list) { HWYDIOProc(0, &stamp, $0, &input, $0, &output, UnsafeMutableRawPointer(ring)) }
        }
        while true {
            let micTime = Double(micBlock * micFrames) / 16000
            // The tap clock runs fast: its frames cover less host time than nominal.
            let systemTime = systemStart + Double(systemBlock * systemFrames) / (48000 * (1 + skew))
            if micTime > seconds && systemTime > seconds { break }
            if micTime <= systemTime {
                for f in 0..<micFrames {
                    let t = micTime + Double(f) / 16000
                    micSamples[f] = t >= click && t < click + 0.001 ? 0.9 : 0.2
                }
                push(micRing, micSamples, channels: 1, frames: micFrames, at: micTime); micBlock += 1
            } else {
                for f in 0..<systemFrames {
                    let t = systemTime + Double(f) / (48000 * (1 + skew))
                    let value: Float = t >= click && t < click + 0.001 ? 0.9 : 0.6
                    systemSamples[f * 2] = value; systemSamples[f * 2 + 1] = value
                }
                push(systemRing, systemSamples, channels: 2, frames: systemFrames, at: systemTime); systemBlock += 1
            }
            writer.consumeForTest()
        }
        let chunks = writer.finish()
        guard writer.status().error == nil else { throw CaptureFailure(message: "Split capture failed: \(writer.status().error!)") }
        var clicks: [Double] = []
        for source in [AudioSource.mic, .system] {
            let track = chunks.filter { $0.source == source }
            guard track.count == 1 else { throw CaptureFailure(message: "Split capture: \(track.count) chunks for \(source)") }
            let file = try AVAudioFile(forReading: directory.appendingPathComponent(track[0].relativePath))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let data = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            guard let index = data.firstIndex(where: { $0 > 0.8 }) else { throw CaptureFailure(message: "Split capture: no click on \(source)") }
            let middle = data[data.count / 2], expected: Float = source == .mic ? 0.2 : 0.6
            guard abs(middle - expected) < 0.015 else { throw CaptureFailure(message: "Split capture: tracks mixed, \(middle) instead of \(expected)") }
            clicks.append(Double(index) / 16000)
        }
        let durations = [AudioSource.mic, .system].map { source in chunks.filter { $0.source == source }.reduce(0) { $0 + $1.duration } }
        guard durations[0] == durations[1], durations[0] > seconds - systemStart - 0.5 else { throw CaptureFailure(message: "Split capture durations \(durations)") }
        // Without correction the tap would lag by click × skew = 20 ms here, plus its 250 ms late start.
        guard abs(clicks[0] - clicks[1]) < 0.003, abs(clicks[0] - (click - systemStart)) < 0.01 else {
            throw CaptureFailure(message: String(format: "Split capture misaligned: click at %.4f s on mic, %.4f s on system (corrections %lld/%lld)", clicks[0], clicks[1], writer.corrections[0], writer.corrections[1]))
        }
    }
}
