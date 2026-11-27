import Combine
import CoreAudio
import Darwin
import Foundation
import HWYDCore

/// Which other applications read the microphone or play audio, from Core Audio's process objects.
/// Never opens a device. Core Audio reports a process that starts or stops audio altogether
/// (`kAudioProcessPropertyIsRunning`) and nothing when it releases the microphone while it keeps
/// playing: `kAudioProcessPropertyIsRunningInput` and `IsRunningOutput` have no notification
/// (measured with a probe, November 2026). Hence the reading every two seconds while attending
/// closely, and none otherwise. The HAL is read on a queue of its own, never on the main thread.
@MainActor final class CoreAudioActivity: AudioActivity {
    private let subject = PassthroughSubject<[AppAudioActivity], Never>()
    private let reader = Reader()
    private var attention = AudioAttention.off

    var readings: AnyPublisher<[AppAudioActivity], Never> { subject.eraseToAnyPublisher() }
    func attend(_ attention: AudioAttention) {
        guard attention != self.attention else { return }
        self.attention = attention
        reader.attend(attention) { [weak self] reading in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.subject.send(reading) } }
        }
    }

    /// Its state is only touched on its queue.
    private final class Reader: @unchecked Sendable {
        private let queue = DispatchQueue(label: "dev.lepee.hwyd.audio-activity", qos: .utility)
        private var attention = AudioAttention.off
        private var deliver: (@Sendable ([AppAudioActivity]) -> Void)?
        private var list: DeviceWatch?
        private var processes: [AudioObjectID: DeviceWatch] = [:]
        /// The application of each process object; nil for our own process and for one outside any application.
        private var apps: [AudioObjectID: ConversationApp?] = [:]
        private var pending: DispatchWorkItem?
        private var timer: DispatchSourceTimer?
        private var last: [AppAudioActivity]?

        func attend(_ attention: AudioAttention, deliver: @escaping @Sendable ([AppAudioActivity]) -> Void) {
            queue.async { [self] in
                let was = self.attention
                self.attention = attention; self.deliver = deliver
                timer?.cancel(); timer = nil
                guard attention != .off else { stop(); return }
                if attention == .closely {
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
                    timer.setEventHandler { [weak self] in self?.read() }
                    timer.resume()
                    self.timer = timer
                }
                guard was == .off else { return }
                list = DeviceWatch(listeners: [(HAL.system, HAL.address(kAudioHardwarePropertyProcessObjectList))], queue: queue) { [weak self] in self?.changed() }
                read()
            }
        }
        private func stop() {
            pending?.cancel(); pending = nil
            list?.cancel(); list = nil
            processes.values.forEach { $0.cancel() }
            processes = [:]; apps = [:]; last = nil
        }
        /// A process that opens the microphone notifies several times within a few milliseconds.
        private func changed() {
            pending?.cancel()
            let read = DispatchWorkItem { [weak self] in self?.read() }
            pending = read
            queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: read)
        }
        private func read() {
            guard attention != .off else { return }
            let current = HAL.processObjects()
            for gone in Set(processes.keys).subtracting(current) {
                processes.removeValue(forKey: gone)?.cancel()
                apps.removeValue(forKey: gone)
            }
            for object in current where processes[object] == nil {
                processes[object] = DeviceWatch(listeners: [(object, HAL.address(kAudioProcessPropertyIsRunning))], queue: queue) { [weak self] in self?.changed() }
            }
            let reading = current.compactMap { object -> AppAudioActivity? in
                let input = HAL.flag(object, kAudioProcessPropertyIsRunningInput), output = HAL.flag(object, kAudioProcessPropertyIsRunningOutput)
                guard input || output, let app = app(of: object) else { return nil }
                return AppAudioActivity(app: app, readsMicrophone: input, playsAudio: output)
            }
            guard attention == .closely || reading != last else { return }
            last = reading
            deliver?(reading)
        }
        private func app(of object: AudioObjectID) -> ConversationApp? {
            if let known = apps[object] { return known }
            let app = (try? HAL.scalar(object, kAudioProcessPropertyPID, as: pid_t.self)).flatMap { $0 == getpid() ? nil : Self.app(of: $0) }
            apps[object] = .some(app)
            return app
        }
        private static func app(of pid: pid_t) -> ConversationApp? {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
                  let path = ConversationApp.bundlePath(ofExecutable: String(cString: buffer)), let bundle = Bundle(path: path) else { return nil }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return ConversationApp(id: bundle.bundleIdentifier ?? path, name: name)
        }
    }
}
