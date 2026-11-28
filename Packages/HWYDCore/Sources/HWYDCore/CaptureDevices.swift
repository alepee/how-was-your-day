import Foundation

/// What a running capture makes of the devices it watches. The adapter reads the hardware (the
/// inputs, the default input and output, whether the microphone in use is alive) and acts on the
/// answer; this type holds the rules, so they are tested without hardware.
///
/// - The input list and the default input are reported when they differ from what was last
///   reported. Only a check moves that reference: a switch asked by the session reads the devices
///   without touching it, so a change it saw first is still reported by the next check.
/// - The microphone in use is lost when it leaves the list or stops being alive. Nothing else is
///   decided for it until the session switches.
/// - A new default output asks for the system audio tap to be built again. When the microphone is
///   lost at the same time, the next switch builds the tap again instead, and nothing else is
///   rebuilt: one gap, not two.
/// - A new default input, other than the microphone in use, is offered.
public struct CaptureDevices: Equatable, Sendable {
    /// What the adapter should do, in order.
    public enum Action: Equatable, Sendable {
        /// Report the new list (`CaptureEvent.microphonesChanged`).
        case report(MicrophoneList)
        /// The microphone in use disappeared: stop the stream and report it.
        case lose(MicrophoneDevice)
        /// The default output changed: build the tap and the graph again on the same microphone.
        case rebuildForOutput
        /// The default input moved to this device: offer it.
        case offer(MicrophoneDevice)
    }

    /// The list last reported to the session.
    public private(set) var reported: MicrophoneList
    /// The default output the tap was built for, as an opaque Core Audio identifier.
    public private(set) var output: UInt32
    /// The microphone recorded.
    public private(set) var microphone: MicrophoneDevice?
    /// The microphone recorded disappeared; the stream stands still until the next switch.
    public private(set) var isLost = false
    /// The default output changed since the tap was built.
    public private(set) var outputChanged = false

    public init(list: MicrophoneList, output: UInt32, microphone: MicrophoneDevice?) {
        reported = list; self.output = output; self.microphone = microphone
    }

    /// One look at the devices.
    /// - Parameters:
    ///   - list: the inputs present and the default input, as read now.
    ///   - output: the default output now.
    ///   - microphoneAlive: whether the microphone in use still reports itself alive.
    public mutating func check(list: MicrophoneList, output: UInt32, microphoneAlive: Bool) -> [Action] {
        var actions: [Action] = []
        let previousDefault = reported.defaultInput
        if list != reported { reported = list; actions.append(.report(list)) }
        if output != self.output { self.output = output; outputChanged = true }
        guard let microphone, !isLost else { return actions }
        if list.device(microphone.uid) == nil || !microphoneAlive {
            isLost = true
            actions.append(.lose(microphone))
            return actions
        }
        if outputChanged { actions.append(.rebuildForOutput) }
        if list.defaultInput != previousDefault, let offered = list.defaultDevice, offered.uid != microphone.uid {
            actions.append(.offer(offered))
        }
        return actions
    }

    /// The graph runs on `device` now. `newTap` says whether the tap was built again with it.
    public mutating func switched(to device: MicrophoneDevice, newTap: Bool) {
        microphone = device; isLost = false
        if newTap { outputChanged = false }
    }
    /// The tap was built again for the current output.
    public mutating func tapRebuilt() { outputChanged = false }
}

/// One device operation at a time in a capture: a check of the devices, or a rebuild of the
/// graph. A notification that comes while one runs never interrupts it: one more check follows
/// it instead. This is what keeps a rebuild, which waits for the first buffers of the new device,
/// from being cancelled by the notifications it causes itself (the aggregate it creates, a
/// Bluetooth headset that changes mode).
public struct DeviceCheckGate: Equatable, Sendable {
    public private(set) var isBusy = false
    /// A notification came while busy: check again once free.
    public private(set) var isPending = false
    public init() {}

    /// A device notification. True when the caller should schedule a check after the usual
    /// settling delay; false when an operation runs, which checks again once it ends.
    public mutating func notified() -> Bool {
        if isBusy { isPending = true; return false }
        return true
    }
    /// Starts an operation. False when another runs: a check is then postponed until it ends,
    /// and a switch is refused.
    public mutating func begin() -> Bool {
        if isBusy { isPending = true; return false }
        isBusy = true; isPending = false
        return true
    }
    /// Ends the operation. True when a check must follow.
    public mutating func end() -> Bool {
        isBusy = false
        defer { isPending = false }
        return isPending
    }
}

/// Waiting for the first buffers of devices that just started.
public enum AudioWait {
    /// What the capture sees on one look.
    public enum Probe: Equatable, Sendable {
        /// Both tracks deliver.
        case flowing
        /// Nothing yet.
        case waiting
        /// The capture was paused meanwhile: the devices are stopped.
        case paused
        /// The capture stopped meanwhile.
        case stopped
        /// The writer failed.
        case failed(String)
        /// The device changed its channel count: the graph refuses its buffers and must be built again.
        case formatChanged
    }
    public enum Outcome: Equatable, Sendable { case flowing, paused, stopped, formatChanged }
    public struct Timeout: Error, Equatable {}
    public struct Failure: Error, Equatable { public var message: String }

    /// Looks every `interval` until the audio flows, the capture pauses or stops, the writer
    /// fails (throws `Failure`) or `deadline` passes (throws `Timeout`). Cancelling the calling
    /// task does not end the wait: only the deadline does.
    public static func until(_ deadline: ContinuousClock.Instant, every interval: Duration = .milliseconds(50),
                             probe: () async -> Probe) async throws -> Outcome {
        while true {
            switch await probe() {
            case .flowing: return .flowing
            case .paused: return .paused
            case .stopped: return .stopped
            case .formatChanged: return .formatChanged
            case .failed(let message): throw Failure(message: message)
            case .waiting: break
            }
            guard ContinuousClock.now < deadline else { throw Timeout() }
            await sleep(interval)
        }
    }

    /// A sleep that cancellation does not cut short.
    static func sleep(_ duration: Duration) async {
        let parts = duration.components
        let nanoseconds = Int(parts.seconds) * 1_000_000_000 + Int(parts.attoseconds / 1_000_000_000)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { done.resume() }
        }
    }
}
