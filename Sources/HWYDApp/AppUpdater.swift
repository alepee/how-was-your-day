import Combine
import Foundation
import Sparkle

/// In-app updates through Sparkle. Only release builds carry a feed (`SUFeedURL`, set by
/// `scripts/build-app.sh` when `VERSION` is given): development and CI builds never check, so a
/// local build is not replaced by the public release. Synthetic modes never start the updater.
///
/// A relaunch never interrupts a capture or the processing of a recording: Sparkle's relaunch is
/// postponed until the app is idle, and scheduled checks are skipped while it is busy.
@MainActor final class AppUpdater: NSObject, ObservableObject {
    /// False in builds without a feed or a public key, and in synthetic modes.
    @Published private(set) var isAvailable = false
    @Published private(set) var canCheckForUpdates = false
    /// An update is downloaded and waits for the current capture or processing to end.
    @Published private(set) var isWaitingForIdle = false
    @Published var automaticallyChecks = false {
        didSet { if let updater, updater.automaticallyChecksForUpdates != automaticallyChecks { updater.automaticallyChecksForUpdates = automaticallyChecks } }
    }
    @Published var automaticallyDownloads = false {
        didSet { if let updater, updater.automaticallyDownloadsUpdates != automaticallyDownloads { updater.automaticallyDownloadsUpdates = automaticallyDownloads } }
    }
    @Published private(set) var lastCheck: Date?

    private var controller: SPUStandardUpdaterController?
    private var updater: SPUUpdater? { controller?.updater }
    private var isBusy: () -> Bool = { false }
    private var pendingRelaunch: (() -> Void)?
    private var observers: Set<AnyCancellable> = []

    /// Starts the updater when the bundle carries a feed. `isBusy` reports a capture or a
    /// processing job in progress; `busyChanges` fires when that state may have changed.
    func start(isBusy: @escaping () -> Bool, busyChanges: AnyPublisher<Void, Never>) {
        guard controller == nil, Self.bundleHasFeed else { return }
        self.isBusy = isBusy
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        do { try controller.updater.start() } catch {
            FileHandle.standardError.write(Data("HWYD updater unavailable: \(error)\n".utf8))
            self.controller = nil; return
        }
        isAvailable = true
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }.store(in: &observers)
        updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] in if self?.automaticallyChecks != $0 { self?.automaticallyChecks = $0 } }.store(in: &observers)
        updater.publisher(for: \.automaticallyDownloadsUpdates).receive(on: DispatchQueue.main)
            .sink { [weak self] in if self?.automaticallyDownloads != $0 { self?.automaticallyDownloads = $0 } }.store(in: &observers)
        updater.publisher(for: \.lastUpdateCheckDate).receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.lastCheck = $0 }.store(in: &observers)
        busyChanges.receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.relaunchIfIdle() }.store(in: &observers)
    }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    private func relaunchIfIdle() {
        guard let pendingRelaunch, !isBusy() else { return }
        self.pendingRelaunch = nil
        isWaitingForIdle = false
        pendingRelaunch()
    }

    private static var bundleHasFeed: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let feed = info["SUFeedURL"] as? String, feed.hasPrefix("https://"),
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty else { return false }
        return true
    }
}

// SPUUpdaterDelegate is main-actor isolated (NS_SWIFT_UI_ACTOR).
extension AppUpdater: SPUUpdaterDelegate {
    /// Skips scheduled checks during a capture or processing, so no update window appears in the
    /// middle of a meeting. A check the user asks for always runs.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard updateCheck == .updatesInBackground, isBusy() else { return }
        throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue), userInfo: [NSLocalizedDescriptionKey: "Capture or processing in progress"])
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        pendingRelaunch = installHandler
        isWaitingForIdle = true
        return true
    }
}

extension AppUpdater: SPUStandardUserDriverDelegate {
    /// The app spends most of its time as a menu bar item: Sparkle shows scheduled updates
    /// without taking focus.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
