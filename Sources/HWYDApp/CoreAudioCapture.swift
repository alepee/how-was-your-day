import AVFoundation
import CoreAudio
import Foundation
import HWYDCore
import HWYDRealtime

struct CaptureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
/// The Core Audio adapter of `AudioCapture`: a process tap and the chosen microphone, in one
/// aggregate device or on two clocks, written as CAF chunks by `AudioWriter`. HAL calls, the health
/// checks, the device listeners and the rebuilds of the graph run on the actor's own serial queue,
/// never on the main thread: starting or restarting a tap aggregate can block for about a second.
///
/// The capture detects the devices; the session decides. A new system default input is reported as
/// an offer, a microphone that disappears as lost, and the graph is rebuilt on the microphone the
/// session asks for. A change of the default output device rebuilds the graph on the same
/// microphone, silently, framed by `restarting` and `restarted(gap:)`.
///
/// The realtime IOProc (`HWYDRealtime`) only copies into a ring; the writer drains it on its own
/// queue. Rings are allocated and released here, never in the callback, and only once the IOProc
/// that fills them is destroyed.
actor CoreAudioCapture: AudioCapture {
    private let queue = DispatchSerialQueue(label: "dev.lepee.hwyd.capture", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    nonisolated let isSimulated = false
    nonisolated let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    private let audio: any AudioLocator
    private var session = UUID()
    /// Each graph gets its own aggregate UID.
    private var generation = 0
    private var tap: AudioObjectID = 0
    private var tapUID = ""
    /// Microphone plus tap on one clock, or the tap alone when the microphone runs on its own clock.
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var ring: OpaquePointer?
    /// Split mode only: the microphone device runs its own IOProc into its own ring.
    private var micDevice: AudioObjectID = 0
    private var micProc: AudioDeviceIOProcID?
    private var micRing: OpaquePointer?
    private var writer: AudioWriter?
    private var lockFD: Int32 = -1
    /// The microphone recorded, the devices as last reported and what changes mean (`CaptureDevices`).
    private var devices: CaptureDevices?
    var microphone: MicrophoneDevice? { devices?.microphone }
    var microphones: MicrophoneList { devices?.reported ?? MicrophoneList() }
    /// Paused: the devices are stopped, so neither the microphone nor system audio is captured.
    private var isPaused = false
    /// One device check or rebuild at a time; notifications meanwhile check again after it.
    private var gate = DeviceCheckGate()
    /// The graph was built but has not delivered yet: it was built while paused, or paused before
    /// its first buffers. Resuming waits for them, as a switch does.
    private var awaitingAudio = false
    /// When the stream stopped delivering, in `systemUptime` seconds, for a restart, a rebuild or a
    /// lost microphone.
    private var stillSince: TimeInterval?
    /// Restarts the microphone stream once another app opened the input after the capture started.
    private var claimWatch: MicrophoneClaimWatch?
    private var lastClaimPoll: TimeInterval = 0
    /// Checks levels, speech, health and microphone claims five times per second while recording.
    private var monitor: Task<Void, Never>?
    /// The writer's count of windows with speech at the last check.
    private var speechHeard = 0
    /// Listens to the devices and the default input and output, and to the microphone in use.
    private var watch: DeviceWatch?
    private var alive: DeviceWatch?
    /// Waits for device notifications to settle. Only the wait is ever cancelled, never a check.
    private var settle: Task<Void, Never>?
    private var settleIsImmediate = false
    /// A fault was reported: the session stops the capture, nothing else is checked.
    private var faulted = false

    /// - Parameter audio: where each session's chunks go (`audio/<session>` under the store's directory).
    init(audio: any AudioLocator) {
        self.audio = audio
        (events, continuation) = AsyncStream.makeStream(of: CaptureEvent.self)
    }
    private static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// The fault that must stop the session, if any.
    private func fault() -> CaptureFault? {
        guard let status = writer?.status() else { return nil }
        if let error = status.error { return CaptureFault(.writer, message: error) }
        if !isPaused, let lastPacket = status.lastPacket, Self.uptime - lastPacket > 3 {
            return CaptureFault(.stalled, message: String(localized: "Le périphérique ne fournit plus de données audio. La session a été arrêtée."))
        }
        return nil
    }
    func start(session id: UUID, continuing start: CaptureContinuation, microphone uid: String?) async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw CaptureFailure(message: String(localized: "L’accès au micro est refusé. Autorisez HWYD dans Réglages Système > Confidentialité et sécurité > Microphone.")) }
        lockFD = open(audio.captureLockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD); lockFD = -1 }
            throw CaptureFailure(message: String(localized: "Une autre instance de HWYD enregistre déjà une session."))
        }
        do {
            session = id
            let list = HAL.microphones(), output = HAL.defaultOutput
            // The chosen microphone, else the system default input, else the first recordable one
            // (the default input may be an aggregate or a virtual device the capture cannot record).
            guard let device = list.device(uid) ?? list.defaultDevice ?? list.devices.first else { throw CaptureFailure(message: String(localized: "Aucun microphone disponible.")) }
            try createTap()
            let inputs = try buildGraph(on: device)
            let folder = try audio.sessionFolder(for: id)
            // A resumed session's files are never written over, even one its chunks do not list.
            writer = AudioWriter(inputs: inputs, folder: folder, startFrames: start.offsetFrames,
                                 firstSequence: max(start.firstSequence, CaptureContinuation.firstFreeSequence(in: folder.url)), detectsSpeech: true)
            speechHeard = 0
            // Drain before the devices start: starting a tap aggregate can block for about a second.
            writer?.start()
            try startDevices()
            try await waitForAudio(seconds: 5)
            devices = CaptureDevices(list: list, output: output, microphone: device)
            claimWatch = MicrophoneClaimWatch(readers: inputReaders())
            watch = HAL.watchDevices(on: queue) { [weak self] in Task { await self?.devicesChanged() } }
        } catch { _ = teardown(); continuation.finish(); throw error }
        startMonitor()
    }
    /// Stops the devices without ending the session. Buffered audio is written first.
    /// The audio timeline skips the pause: chunks continue where the last frame ended.
    func pause() {
        guard !isPaused, writer != nil else { return }
        // A restart in progress ends here for the session clock: the pause is not part of its gap.
        restarted()
        halt()
        isPaused = true
    }
    func resume() async throws {
        guard isPaused, let writer else { return }
        isPaused = false
        // Nothing to start until the session switched: the stream still stands still.
        if devices?.isLost == true { continuation.yield(.restarting); stillSince = Self.uptime; return }
        if awaitingAudio {
            // A graph built during the pause may be a Bluetooth headset still switching to call
            // mode: wait for its first buffers as a switch does, before the session clock runs.
            writer.rearm()
            do {
                try startDevices()
                if try await waitForAudio(seconds: 8) == .flowing { awaitingAudio = false }
            } catch {
                if self.writer != nil { halt(); isPaused = true }
                throw error
            }
        } else {
            writer.resume()
            do { try startDevices() } catch { isPaused = true; throw error }
        }
        claimWatch?.reset(readers: inputReaders())
    }
    func stop() -> CapturedAudio {
        let audio = teardown()
        continuation.finish()
        return audio
    }
    /// Stops the devices and writes what their rings hold.
    private func halt() {
        stopDevices()
        writer?.pause()
    }

    // MARK: Microphone

    func switchMicrophone(to uid: String, reason: MicrophoneSwitchReason) async throws {
        guard writer != nil, !faulted, let state = devices else { throw CaptureFailure(message: String(localized: "Aucune capture en cours.")) }
        // Read without moving what the checks compare with: a change seen here first is still
        // reported, and offered, by the next check.
        guard let target = HAL.microphones().device(uid) else { throw CaptureFailure(message: String(localized: "Ce micro n’est plus branché.")) }
        guard gate.begin() else { throw CaptureFailure(message: String(localized: "Un changement de micro est déjà en cours.")) }
        defer { if gate.end() { devicesChanged() } }
        let previous = state.microphone, wasLost = state.isLost
        // The output changed while the microphone was lost: the tap is built again with the new microphone.
        let newTap = state.outputChanged
        if !isPaused, !wasLost { continuation.yield(.restarting); stillSince = Self.uptime }
        do {
            try await rebuild(on: target, newTap: newTap)
            devices?.switched(to: target, newTap: newTap)
            // The stream runs again first, so the session dates the boundary on its corrected clock.
            restarted()
            continuation.yield(.microphoneSwitched(target, reason: reason))
        } catch {
            // Stopped meanwhile: nothing is left to go back to.
            guard writer != nil else { throw error }
            // Back to the previous microphone if it is still there, once.
            if !wasLost, let previous, HAL.device(uid: previous.uid) != 0, (try? await rebuild(on: previous, newTap: false)) != nil {
                restarted()
                throw CaptureFailure(message: String(localized: "\(target.name) n’a pas pu démarrer (\(error.localizedDescription)). L’enregistrement continue sur \(previous.name)."))
            }
            guard writer != nil else { throw error }
            report(CaptureFault(.restart, message: String(localized: "Aucun micro n’a pu redémarrer : \(error.localizedDescription). La session a été arrêtée, l’audio est conservé.")))
            throw error
        }
    }
    /// The stream runs again, unless the capture is paused: the session clock skips the gap.
    private func restarted() {
        defer { stillSince = nil }
        guard !isPaused, let stillSince else { return }
        continuation.yield(.restarted(gap: max(0, Self.uptime - stillSince)))
    }
    /// Device notifications come in bursts (AirPods change the input, then the output): they are
    /// checked once they settle, 500 ms after the last one. The microphone in use that stops being
    /// alive is checked at once. A check or rebuild in progress is never interrupted: it checks
    /// again when it ends.
    private func devicesChanged(after delay: Duration = .milliseconds(500)) {
        guard writer != nil, !faulted, gate.notified() else { return }
        // A check already due at once covers this change too.
        if delay != .zero, settleIsImmediate { return }
        settle?.cancel()
        settleIsImmediate = delay == .zero
        settle = Task { [weak self] in
            if delay != .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.settled()
        }
    }
    private func settled() async {
        settleIsImmediate = false
        guard writer != nil, !faulted, gate.begin() else { return }
        await checkDevices()
        if gate.end() { devicesChanged() }
    }
    /// One look at the devices; the gate is held by the caller.
    private func checkDevices() async {
        guard writer != nil, !faulted, var state = devices else { return }
        let alive = state.microphone.map { HAL.isAlive(HAL.device(uid: $0.uid)) } ?? true
        let actions = state.check(list: HAL.microphones(), output: HAL.defaultOutput, microphoneAlive: alive)
        devices = state
        for action in actions {
            guard writer != nil, !faulted else { return }
            switch action {
            case .report(let list): continuation.yield(.microphonesChanged(list))
            case .lose(let device): lose(device)
            case .rebuildForOutput: if let current = devices?.microphone { await rebuildForOutput(on: current) }
            case .offer(let device): continuation.yield(.microphoneOffered(device))
            }
        }
    }
    /// The microphone in use disappeared: its devices stop, what the rings hold is written, and
    /// buffers lost as it went away are not a writer failure. The stream stood still since the
    /// microphone's last buffer, not since now: in split mode system audio kept coming, and what it
    /// holds beyond the microphone is dropped, so the session clock skips that time too.
    private func lose(_ device: MicrophoneDevice) {
        let lastPacket = writer?.lastPacket(track: 0)
        stopDevices()
        writer?.detach(forgivingDrops: true)
        if !isPaused { continuation.yield(.restarting); stillSince = min(Self.uptime, lastPacket ?? Self.uptime) }
        continuation.yield(.microphoneLost(device))
    }
    /// Whether a global tap follows a new output device on its own is not established: the tap and
    /// the graph are built again on the same microphone, which costs a short gap and no boundary.
    private func rebuildForOutput(on device: MicrophoneDevice) async {
        if !isPaused { continuation.yield(.restarting); stillSince = Self.uptime }
        do {
            try await rebuild(on: device, newTap: true)
            devices?.tapRebuilt()
            restarted()
        } catch {
            guard writer != nil else { return }
            report(CaptureFault(.restart, message: String(localized: "La capture n’a pas pu repartir après un changement de sortie audio : \(error.localizedDescription). La session a été arrêtée, l’audio est conservé.")))
        }
    }

    // MARK: Graph

    private func createTap() throws {
        var processAddress = HAL.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid(), process: AudioObjectID = 0, size = UInt32(MemoryLayout<AudioObjectID>.size)
        let processResult = AudioObjectGetPropertyData(HAL.system, &processAddress, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process)
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: processResult == noErr && process != 0 ? [process] : [])
        description.name = "HWYD System Audio"; description.isPrivate = true; description.muteBehavior = .unmuted
        try HAL.check(AudioHardwareCreateProcessTap(description, &tap), String(localized: "Création du tap audio système"))
        tapUID = description.uuid.uuidString
    }
    /// Builds the aggregate and the IOProcs for `device`, without starting them, and allocates
    /// their rings. Combined when the microphone runs at the tap's rate, split otherwise.
    private func buildGraph(on device: MicrophoneDevice) throws -> [CaptureInput] {
        let input = HAL.device(uid: device.uid)
        guard input != 0 else { throw CaptureFailure(message: String(localized: "\(device.name) n’est plus branché.")) }
        let micName = device.name
        let micStreams = try HAL.streams(input)
        guard micStreams.count == 1 else { throw CaptureFailure(message: String(localized: "Ce prototype prend en charge les microphones à un seul flux d’entrée. Sélectionnez le micro du Mac.")) }
        let micFormat = try HAL.format(micStreams[0])
        let micChannels = micFormat.mChannelsPerFrame
        let tapRate = try HAL.scalar(tap, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self).mSampleRate
        generation += 1
        let inputs: [CaptureInput]
        if micFormat.mSampleRate == tapRate {
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "HWYD Capture",
                kAudioAggregateDeviceUIDKey: "\(HAL.ownPrefix)capture.\(session.uuidString).\(generation)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: device.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: device.uid]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
                // Do not wait for a tapped app to play: room conversations must start immediately.
                kAudioAggregateDeviceTapAutoStartKey: false
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), String(localized: "Création du périphérique agrégé"))
            let aggregateStreams = try HAL.streams(aggregate)
            guard aggregateStreams.count == 2 else { throw CaptureFailure(message: String(localized: "Le graphe audio n’expose pas les deux flux attendus. La capture est annulée, sans piste partielle.")) }
            let formats = try aggregateStreams.map { try HAL.format($0) }
            // The explicitly ordered subdevice list precedes the tap. Verify its stream layout.
            let starts = try aggregateStreams.map { try HAL.scalar($0, kAudioStreamPropertyStartingChannel, as: UInt32.self) }
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
                kAudioAggregateDeviceUIDKey: "\(HAL.ownPrefix)system.\(session.uuidString).\(generation)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: false]],
                kAudioAggregateDeviceTapAutoStartKey: false
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), String(localized: "Création du périphérique agrégé"))
            let systemStreams = try HAL.streams(aggregate)
            guard systemStreams.count == 1 else { throw CaptureFailure(message: String(localized: "Le graphe audio n’expose pas le flux système attendu (\(systemStreams.count) flux). La capture est annulée, sans piste partielle.")) }
            let systemFormat = try HAL.format(systemStreams[0])
            try validateSplitLayout(mic: micFormat, system: systemFormat, micName: micName)
            guard let systemRing = HWYDRingCreate(2) else { throw CaptureFailure(message: String(localized: "Mémoire insuffisante pour préparer la capture.")) }
            ring = systemRing
            guard let createdMicRing = HWYDRingCreate(micChannels) else { throw CaptureFailure(message: String(localized: "Mémoire insuffisante pour préparer la capture.")) }
            micRing = createdMicRing
            micDevice = input
            inputs = [
                CaptureInput(ring: createdMicRing, channels: Int(micChannels), sampleRate: micFormat.mSampleRate, layout: .mic),
                CaptureInput(ring: systemRing, channels: 2, sampleRate: systemFormat.mSampleRate, layout: .system)
            ]
        }
        try HAL.check(AudioDeviceCreateIOProcID(aggregate, HWYDIOProc, UnsafeMutableRawPointer(ring), &ioProc), String(localized: "Préparation de la capture"))
        if let micRing { try HAL.check(AudioDeviceCreateIOProcID(micDevice, HWYDIOProc, UnsafeMutableRawPointer(micRing), &micProc), String(localized: "Préparation du micro")) }
        alive = DeviceWatch(listeners: [(input, HAL.address(kAudioDevicePropertyDeviceIsAlive))], queue: queue) { [weak self] in Task { await self?.devicesChanged(after: .zero) } }
        return inputs
    }
    private func startDevices() throws {
        guard let ioProc, aggregate != 0 else { return }
        try HAL.check(AudioDeviceStart(aggregate, ioProc), String(localized: "Démarrage de la capture"))
        if let micProc { try HAL.check(AudioDeviceStart(micDevice, micProc), String(localized: "Démarrage du micro")) }
    }
    /// Once this returns, the IOProcs no longer run: a device that disappeared just reports an error.
    private func stopDevices() {
        if let ioProc, aggregate != 0 { AudioDeviceStop(aggregate, ioProc) }
        if let micProc, micDevice != 0 { AudioDeviceStop(micDevice, micProc) }
    }
    /// Stops and destroys the IOProcs and the aggregate. The rings stay until the writer let go of them.
    private func destroyGraph() {
        stopDevices()
        alive?.cancel(); alive = nil
        if let ioProc, aggregate != 0 { AudioDeviceDestroyIOProcID(aggregate, ioProc) }
        if let micProc, micDevice != 0 { AudioDeviceDestroyIOProcID(micDevice, micProc) }
        ioProc = nil; micProc = nil; micDevice = 0
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
    }
    private func releaseRings() {
        if let ring { HWYDRingDestroy(ring); self.ring = nil }
        if let micRing { HWYDRingDestroy(micRing); self.micRing = nil }
    }
    /// Builds the graph again on `device`: the writer writes what the old rings hold, the old graph
    /// goes, the new one is built in combined or split mode, and the writer reads it on the same
    /// files and chunk sequence, its clocks anchored again. Started unless paused; a pause or a
    /// stop while it waits for the first buffers ends the wait, and a resume waits for them.
    private func rebuild(on device: MicrophoneDevice, newTap: Bool) async throws {
        guard let writer else { throw CaptureFailure(message: String(localized: "Aucune capture en cours.")) }
        destroyGraph()
        writer.detach()
        releaseRings()
        if newTap {
            if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
            try createTap()
        }
        do {
            let inputs = try buildGraph(on: device)
            writer.attach(inputs)
        } catch { destroyGraph(); releaseRings(); throw error }
        awaitingAudio = true
        guard !isPaused else { return }
        try startDevices()
        // A Bluetooth headset may take more than a second to switch to call mode.
        let outcome = try await waitForAudio(seconds: 8)
        guard self.writer != nil else { throw CaptureFailure(message: String(localized: "Aucune capture en cours.")) }
        guard outcome == .flowing else { return }
        awaitingAudio = false
        claimWatch?.reset(readers: inputReaders())
    }
    /// Waits for the first buffers of both tracks. Returns early if the capture is paused or
    /// stopped meanwhile. Only the deadline ends the wait: device notifications never cancel it.
    @discardableResult
    private func waitForAudio(seconds: Int) async throws -> AudioWait.Outcome {
        do {
            return try await AudioWait.until(.now.advanced(by: .seconds(seconds))) { [weak self] in await self?.probe() ?? .stopped }
        } catch let failure as AudioWait.Failure {
            throw CaptureFailure(message: failure.message)
        } catch {
            throw CaptureFailure(message: String(localized: "Le périphérique audio a démarré mais aucun buffer n’est reçu. Vérifiez les permissions micro et audio système, puis réessayez."))
        }
    }
    private func probe() -> AudioWait.Probe {
        guard let writer else { return .stopped }
        if isPaused { return .paused }
        let status = writer.status()
        if let error = status.error { return .failed(error) }
        return status.lastPacket == nil ? .waiting : .flowing
    }

    // MARK: Health

    private func startMonitor() {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                await self?.inspect()
            }
        }
    }
    /// One monitor pass: levels, then the fault that ends the session, then a microphone claim.
    /// Lost buffers or a stalled stream first look at the devices: when the microphone in use is
    /// going away, it is a lost microphone for the session to replace, not a fault.
    private func inspect() async {
        guard let writer, !isPaused, !faulted, !gate.isBusy, !awaitingAudio, devices?.isLost != true else { return }
        let status = writer.status()
        continuation.yield(.levels(mic: status.mic, system: status.system))
        let heard = writer.speechHeard
        if heard != speechHeard { speechHeard = heard; continuation.yield(.speech) }
        if let fault = fault() {
            if gate.begin() {
                await checkDevices()
                if gate.end() { devicesChanged() }
            }
            guard self.writer != nil, !faulted, devices?.isLost != true else { return }
            report(fault); return
        }
        do { try restartIfMicrophoneClaimed() } catch { report(CaptureFault(.restart, message: error.localizedDescription)) }
    }
    private func report(_ fault: CaptureFault) {
        faulted = true
        monitor?.cancel(); monitor = nil
        continuation.yield(.failed(fault))
    }
    /// A meeting app that opens the microphone after the capture started may switch on voice processing,
    /// which leaves the stream already running about 30 dB lower. Stopping and starting it again, like a manual
    /// pause and resume, restores the level. The gap lasts a few milliseconds to about a second and, like a pause,
    /// is left out of the timeline; the events let the session clock skip it too.
    private func restartIfMicrophoneClaimed() throws {
        guard !isPaused, claimWatch != nil else { return }
        let now = Self.uptime
        guard now - lastClaimPoll >= 0.5 else { return }
        lastClaimPoll = now
        guard claimWatch?.poll(readers: inputReaders(), now: now) == true else { return }
        continuation.yield(.restarting)
        stillSince = now
        halt()
        writer?.resume()
        try startDevices()
        claimWatch?.reset(readers: inputReaders())
        restarted()
    }
    /// The other processes currently reading audio input, from any device. A meeting app with voice processing
    /// reads through its own aggregate device, so the reader is not filtered on the capture's microphone.
    private func inputReaders() -> Set<Int32> {
        var prop = HAL.address(kAudioHardwarePropertyProcessObjectList), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(HAL.system, &prop, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(HAL.system, &prop, 0, nil, &size, &processes) == noErr else { return [] }
        let own = getpid()
        var readers: Set<Int32> = []
        for process in processes {
            guard (try? HAL.scalar(process, kAudioProcessPropertyIsRunningInput, as: UInt32.self)) ?? 0 != 0,
                  let pid = try? HAL.scalar(process, kAudioProcessPropertyPID, as: pid_t.self), pid != own else { continue }
            readers.insert(pid)
        }
        return readers
    }
    /// Stops and releases everything the capture holds, and seals the audio.
    private func teardown() -> CapturedAudio {
        monitor?.cancel(); monitor = nil
        settle?.cancel(); settle = nil
        watch?.cancel(); watch = nil
        destroyGraph()
        let chunks = writer?.finish() ?? []
        let finalizationError = writer?.status().error
        writer = nil
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        releaseRings()
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
        claimWatch = nil
        return CapturedAudio(chunks: chunks, finalizationError: finalizationError)
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
///
/// The inputs can change while the files stay: `detach` writes what the rings hold and lets go of
/// them, `attach` reads new rings, at their own rates and layout, from where the audio stopped.
/// Like a pause, the time in between is left out of the timeline.
private final class AudioWriter: @unchecked Sendable {
    static let outputRate = 16000.0
    /// Calibration window, then the residual offset tolerated before one sample is dropped or repeated.
    private static let calibrationBuffers = 50
    private static let toleranceSamples = 32.0
    private let queue = DispatchQueue(label: "dev.lepee.hwyd.audio-writer", qos: .userInitiated)
    private let statusLock = NSLock()
    /// `dropped`: the error is buffers the realtime callback could not queue.
    private var state: (mic: Float, system: Float, error: String?, dropped: Bool, lastPackets: [Double?]) = (0, 0, nil, false, [nil, nil])
    private var inputs: [CaptureInput] = []
    private var split = false
    private let folder: AudioFolder
    private var buffers: [UnsafeMutablePointer<Float>] = []
    private let outputFormat: AVAudioFormat
    private var inputFormats: [AVAudioFormat] = []
    private var converters: [AVAudioConverter] = []
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
    /// Listens for speech in the converted samples, for the session's inactivity watch.
    private let speech: SpeechDetector?
    /// How many analysis windows held speech so far, on either track.
    var speechHeard: Int { speech?.heard ?? 0 }
    /// - Parameters:
    ///   - folder: the session's audio folder, created by the locator.
    ///   - startFrames: where the first chunk starts on the session's timeline, at 16 kHz: zero
    ///     for a new session, after the earlier audio when recording resumes. Descriptors record
    ///     it too, so recovery after a crash places the chunks on the same timeline.
    ///   - firstSequence: number of the first chunk pair, past the files already in `folder`.
    ///   - detectsSpeech: analyzes the converted samples for speech (`speechHeard`).
    init(inputs: [CaptureInput], folder: AudioFolder, chunkSeconds: Double = 300, startFrames: Int64 = 0, firstSequence: Int = 0, detectsSpeech: Bool = false) {
        speech = detectsSpeech ? SpeechDetector(sampleRate: Self.outputRate) : nil
        chunkLimit = Int64(chunkSeconds * Self.outputRate)
        outputFrames = startFrames; sequence = firstSequence
        self.folder = folder
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: Self.outputRate, channels: 1)!
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)
        use(inputs)
    }
    deinit { buffers.forEach { $0.deallocate() } }
    /// Reads `inputs` from now on. Track 0 is the microphone, track 1 system audio, whatever input carries them.
    private func use(_ inputs: [CaptureInput]) {
        buffers.forEach { $0.deallocate() }
        self.inputs = inputs
        split = inputs.count == 2
        buffers = inputs.map { .allocate(capacity: 4096 * $0.channels) }
        guard let first = inputs.first else { inputFormats = []; converters = []; return }
        let rates = split ? [inputs[0].sampleRate, inputs[1].sampleRate] : [first.sampleRate, first.sampleRate]
        inputFormats = rates.map { AVAudioFormat(standardFormatWithSampleRate: $0, channels: 1)! }
        converters = inputFormats.map { AVAudioConverter(from: $0, to: outputFormat)! }
    }
    /// Called once the devices stopped: writes what the rings hold, then reads nothing until
    /// `attach`. Samples one track holds beyond the other are dropped, as at a pause in split mode.
    /// `forgivingDrops`: the rings belong to a microphone that disappeared, whose last buffers may
    /// have been refused by the realtime callback; those losses do not fail the writer. Nothing
    /// is desynchronized by them: what follows is anchored again.
    func detach(forgivingDrops: Bool = false) {
        queue.sync {
            drain()
            use([])
            pending = [[], []]; clocks = [TrackClock(), TrackClock()]; origin = nil
            statusLock.lock()
            state.mic = 0; state.system = 0
            if forgivingDrops, state.dropped { state.error = nil; state.dropped = false }
            statusLock.unlock()
        }
    }
    /// Reads new rings, before their devices start. Both clocks are anchored again on their first
    /// buffers; until both tracks deliver, `status().lastPacket` is nil.
    func attach(_ inputs: [CaptureInput]) {
        queue.sync {
            use(inputs)
            pending = [[], []]; clocks = [TrackClock(), TrackClock()]; origin = nil
            statusLock.lock(); state.lastPackets = [nil, nil]; statusLock.unlock()
        }
    }
    func status() -> (mic: Float, system: Float, error: String?, lastPacket: Double?) {
        statusLock.lock(); defer { statusLock.unlock() }
        // Both tracks must flow: one silent device clock would otherwise stall the other track unnoticed.
        let packets = state.lastPackets.compactMap { $0 }
        return (state.mic, state.system, state.error, packets.count == 2 ? packets.min() : nil)
    }
    /// When `track` last delivered, in `systemUptime` seconds; nil before its first buffer.
    func lastPacket(track: Int) -> Double? {
        statusLock.lock(); defer { statusLock.unlock() }
        return state.lastPackets[track]
    }
    /// Waits for the first buffers of both tracks again: `status().lastPacket` is nil until then.
    func rearm() { statusLock.lock(); state.lastPackets = [nil, nil]; statusLock.unlock() }
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
            speech?.finish()
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
    private func setError(_ message: String, dropped: Bool = false) { statusLock.lock(); state.error = message; state.dropped = dropped; statusLock.unlock() }
    private func drain() {
        guard status().error == nil else { return }
        for input in inputs where HWYDRingDropped(input.ring) > 0 {
            let reasons = (0..<4).map { String(HWYDRingDropReason(input.ring, UInt32($0))) }.joined(separator: "/")
            setError(String(localized: "La capture a perdu des buffers audio (\(reasons)). La session est arrêtée pour éviter une désynchronisation silencieuse."), dropped: true); return
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
        speech?.listen(track: track, samples: converted)
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
        try JSONEncoder().encode(descriptor).write(to: folder.url.appendingPathComponent(String(format: "%06d.json", sequence)), options: .atomic)
        files = try ["mic", "system"].map { source in
            try AVAudioFile(forWriting: folder.url.appendingPathComponent(String(format: "%@-%06d.partial.caf", source, sequence)), settings: outputFormat.settings)
        }
    }
    private func seal() throws {
        guard !files.isEmpty else { return }
        files.removeAll()
        for source in [AudioSource.mic, .system] {
            let name = String(format: "%@-%06d.caf", source.rawValue, sequence)
            let temporary = folder.url.appendingPathComponent(String(format: "%@-%06d.partial.caf", source.rawValue, sequence))
            let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
            try FileManager.default.moveItem(at: temporary, to: folder.url.appendingPathComponent(name))
            chunks.append(.init(source: source, relativePath: folder.chunkPath(name), start: Double(outputFrames - chunkFrames) / Self.outputRate, duration: Double(chunkFrames) / Self.outputRate))
        }
        try JSONEncoder().encode(chunks).write(to: folder.url.appendingPathComponent("manifest.json"), options: .atomic)
        chunkFrames = 0
    }
}


extension CoreAudioCapture {
    static func verifySyntheticCapture(audio: any AudioLocator, seconds: Double = 2) throws {
        let id = UUID()
        guard let ring = HWYDRingCreate(3) else { throw CaptureFailure(message: "Ring allocation") }
        defer { HWYDRingDestroy(ring) }
        let writer = try AudioWriter(inputs: [CaptureInput(ring: ring, channels: 3, sampleRate: 48000, layout: .combined(micChannels: 1))], folder: audio.sessionFolder(for: id), chunkSeconds: seconds > 10 ? 300 : 0.5)
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
                let file = try AVAudioFile(forReading: audio.url(for: chunk))
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

    /// Recording resumed in a session: the second capture's chunks follow the first's on the
    /// timeline, are numbered after its files, leave them untouched, and recovery finds both parts.
    static func verifySyntheticResume(audio: DataDirectoryAudio) throws {
        let id = UUID(), folder = try audio.sessionFolder(for: id)
        guard let ring = HWYDRingCreate(3) else { throw CaptureFailure(message: "Ring allocation") }
        defer { HWYDRingDestroy(ring) }
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: 480 * 3)
        defer { samples.deallocate() }
        for i in 0..<480 { samples[i * 3] = 0.2; samples[i * 3 + 1] = 0.6; samples[i * 3 + 2] = 0.6 }
        /// One second of audio in 0.4 s chunks, as one capture.
        func capture(_ continuation: CaptureContinuation) throws -> [AudioChunk] {
            let writer = AudioWriter(inputs: [CaptureInput(ring: ring, channels: 3, sampleRate: 48000, layout: .combined(micChannels: 1))], folder: folder,
                                     chunkSeconds: 0.4, startFrames: continuation.offsetFrames,
                                     firstSequence: max(continuation.firstSequence, CaptureContinuation.firstFreeSequence(in: folder.url)))
            var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 3, mDataByteSize: UInt32(480 * 3 * 4), mData: samples))
            var time = AudioTimeStamp()
            for block in 0..<100 {
                time.mHostTime = UInt64(block * 10_000_000)
                var inputTime = time, outputTime = time
                withUnsafeMutablePointer(to: &input) { pointer in
                    _ = HWYDIOProc(0, &time, pointer, &inputTime, pointer, &outputTime, UnsafeMutableRawPointer(ring))
                }
                writer.consumeForTest()
            }
            let chunks = writer.finish()
            guard writer.status().error == nil, HWYDRingDropped(ring) == 0, chunks.count == 6 else { throw CaptureFailure(message: "Resumed capture: \(writer.status().error ?? "\(chunks.count) chunks")") }
            return chunks
        }
        var session = Recording(title: "Resume", duration: 1.0137) // l10n:ignore
        session.audioChunks = try capture(.start)
        let earlier = try session.audioChunks.map { try Data(contentsOf: audio.url(for: $0)) }
        let continuation = CaptureContinuation(after: session)
        guard continuation.firstSequence == 3, abs(continuation.offset - 1.0137) < 1 / 16000.0 else { throw CaptureFailure(message: "Resume continuation \(continuation)") }
        let added = try capture(continuation)
        guard try session.audioChunks.map({ try Data(contentsOf: audio.url(for: $0)) }) == earlier else { throw CaptureFailure(message: "Resume wrote over earlier audio") }
        guard added.compactMap({ CaptureContinuation.sequence(ofFile: $0.relativePath) }).min() == 3,
              zip(added.filter({ $0.source == .mic }).map(\.start), [0, 0.4, 0.8]).allSatisfy({ abs($0 - continuation.offset - $1) < 1e-9 }) else {
            throw CaptureFailure(message: "Resumed chunks misplaced: \(added.map { "\($0.relativePath) at \($0.start)" })")
        }
        // After a crash, recovery reads every descriptor: both captures, on one timeline.
        // Recovery compares resolved paths: the check's folder may be relative, or under /tmp.
        let root = audio.directory.standardizedFileURL.resolvingSymlinksInPath()
        let recovered = AudioRecovery.merge(stored: session.audioChunks, recovered: try AudioRecovery.recover(in: root, recordingID: id))
        let expected = AudioRecovery.merge(stored: session.audioChunks, recovered: added)
        guard recovered.map(\.relativePath) == expected.map(\.relativePath), zip(recovered, expected).allSatisfy({ abs($0.start - $1.start) < 1e-9 && abs($0.duration - $1.duration) < 1e-9 }) else {
            throw CaptureFailure(message: "Recovery of a resumed session: \(recovered.map { "\($0.relativePath) at \($0.start)" })")
        }
    }

    /// Changing microphone mid-session: a 48 kHz microphone on the tap's clock, then a 16 kHz headset on its own
    /// clock, then the first again. The writer keeps its files: the chunks follow each other on the timeline with one
    /// numbering, both tracks keep identical bounds, and each part holds its own source's audio.
    static func verifySyntheticSwitch(audio: any AudioLocator) throws {
        guard let combinedRing = HWYDRingCreate(3), let micRing = HWYDRingCreate(1), let systemRing = HWYDRingCreate(2), let againRing = HWYDRingCreate(3) else {
            throw CaptureFailure(message: "Ring allocation")
        }
        defer { [combinedRing, micRing, systemRing, againRing].forEach { HWYDRingDestroy($0) } }
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let ticks = 1e9 * Double(timebase.denom) / Double(timebase.numer)
        func push(_ ring: OpaquePointer, value: (mic: Float, system: Float)?, channels: Int, frames: Int, at time: Double, mono: Float = 0) {
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels); defer { samples.deallocate() }
            for f in 0..<frames {
                if let value { samples[f * channels] = value.mic; for c in 1..<channels { samples[f * channels + c] = value.system } }
                else { for c in 0..<channels { samples[f * channels + c] = mono } }
            }
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(frames * channels * 4), mData: samples))
            var stamp = AudioTimeStamp(); stamp.mHostTime = UInt64(1_000_000 + time * ticks)
            var input = stamp, output = stamp
            _ = withUnsafeMutablePointer(to: &list) { HWYDIOProc(0, &stamp, $0, &input, $0, &output, UnsafeMutableRawPointer(ring)) }
        }
        let combined = { (ring: OpaquePointer) in [CaptureInput(ring: ring, channels: 3, sampleRate: 48000, layout: .combined(micChannels: 1))] }
        let writer = try AudioWriter(inputs: combined(combinedRing), folder: audio.sessionFolder(for: UUID()), chunkSeconds: 0.4)
        // Built-in microphone, 0.5 s.
        for block in 0..<50 { push(combinedRing, value: (0.2, 0.6), channels: 3, frames: 480, at: Double(block) * 0.01); writer.consumeForTest() }
        writer.detach()
        // Bluetooth headset in call mode: 16 kHz on its own clock, 0.5 s, after a 1 s rebuild.
        writer.attach([CaptureInput(ring: micRing, channels: 1, sampleRate: 16000, layout: .mic),
                       CaptureInput(ring: systemRing, channels: 2, sampleRate: 48000, layout: .system)])
        for block in 0..<25 {
            let time = 1.5 + Double(block) * 0.02
            push(micRing, value: nil, channels: 1, frames: 320, at: time, mono: 0.3)
            push(systemRing, value: nil, channels: 2, frames: 960, at: time, mono: 0.7)
            writer.consumeForTest()
        }
        writer.detach()
        // Back to the built-in microphone, 0.5 s.
        writer.attach(combined(againRing))
        for block in 0..<50 { push(againRing, value: (0.2, 0.6), channels: 3, frames: 480, at: 3 + Double(block) * 0.01); writer.consumeForTest() }
        let chunks = writer.finish()
        guard writer.status().error == nil else { throw CaptureFailure(message: "Switch capture failed: \(writer.status().error!)") }
        var tracks: [[Float]] = []
        for source in [AudioSource.mic, .system] {
            let track = chunks.filter { $0.source == source }
            let numbers = track.compactMap { CaptureContinuation.sequence(ofFile: $0.relativePath) }
            guard numbers == Array(0..<track.count) else { throw CaptureFailure(message: "Switch capture numbering \(numbers)") }
            for (earlier, later) in zip(track, track.dropFirst()) where abs(earlier.start + earlier.duration - later.start) > 1e-9 {
                throw CaptureFailure(message: "Switch capture: \(later.relativePath) starts at \(later.start), not after \(earlier.relativePath)")
            }
            var samples: [Float] = []
            for chunk in track {
                let file = try AVAudioFile(forReading: audio.url(for: chunk))
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
                try file.read(into: buffer)
                samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            }
            tracks.append(samples)
        }
        let micChunks = chunks.filter { $0.source == .mic }, systemChunks = chunks.filter { $0.source == .system }
        guard micChunks.map(\.start) == systemChunks.map(\.start), micChunks.map(\.duration) == systemChunks.map(\.duration) else {
            throw CaptureFailure(message: "Switch capture: the tracks' chunks differ")
        }
        // The rebuilds are left out: about 1.5 s of audio, a few converter frames short.
        guard tracks[0].count == tracks[1].count, tracks[0].count > 23000, tracks[0].count <= 24000 else {
            throw CaptureFailure(message: "Switch capture: \(tracks.map(\.count)) samples")
        }
        for (time, mic, system) in [(0.25, Float(0.2), Float(0.6)), (0.75, 0.3, 0.7), (1.25, 0.2, 0.6)] {
            let index = Int(time * 16000)
            guard abs(tracks[0][index] - mic) < 0.015, abs(tracks[1][index] - system) < 0.015 else {
                throw CaptureFailure(message: "Switch capture at \(time) s: \(tracks[0][index]) / \(tracks[1][index]), expected \(mic) / \(system)")
            }
        }
    }

    /// Split mode: a 16 kHz microphone and a 48 kHz tap on two clocks, the tap starting 250 ms later and drifting
    /// by 1000 ppm. A click played on both at the same host time must land on the same output sample, within 3 ms.
    static func verifySyntheticSplitCapture(audio: any AudioLocator, seconds: Double = 30) throws {
        guard let micRing = HWYDRingCreate(1), let systemRing = HWYDRingCreate(2) else { throw CaptureFailure(message: "Ring allocation") }
        defer { HWYDRingDestroy(micRing); HWYDRingDestroy(systemRing) }
        let writer = try AudioWriter(inputs: [
            CaptureInput(ring: micRing, channels: 1, sampleRate: 16000, layout: .mic),
            CaptureInput(ring: systemRing, channels: 2, sampleRate: 48000, layout: .system)
        ], folder: audio.sessionFolder(for: UUID()), chunkSeconds: 300)
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
            let file = try AVAudioFile(forReading: audio.url(for: track[0]))
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
