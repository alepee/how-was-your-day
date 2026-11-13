import AppKit
import Combine
import CryptoKit
@preconcurrency import EventKit
@preconcurrency import UserNotifications
import HWYDCore

@MainActor final class CalendarIntegration: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var enabled: Bool
    @Published var reminders: Bool
    @Published var leadMinutes: Int
    @Published var excludedKeywords: String
    @Published var selectedCalendars: Set<String>
    @Published var calendars: [CalendarChoice] = []
    @Published var upcoming: [CalendarContext] = []
    @Published var status = String(localized: "Non connecté")
    @Published var notificationStatus = String(localized: "Notifications non activées")
    @Published var busy = false
    /// Called with the event and whether to open its video link, or nil to only show the app.
    var onAction: ((CalendarContext?, Bool) -> Void)?
    private let settings: SettingsStore
    private let allowed: Bool
    private var active = false
    private var eventStore: EKEventStore?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var refreshing = false
    private var revision = 0
    private var center: UNUserNotificationCenter { .current() }
    static let prefix = "hwyd.meeting."
    struct CalendarChoice: Identifiable { var id: String; var title: String; var account: String }

    init(settings: SettingsStore, allowed: Bool = false) {
        self.settings = settings; self.allowed = allowed
        enabled = allowed && settings.value(.calendarEnabled)
        reminders = allowed && settings.value(.calendarReminders)
        let lead = settings.value(.calendarLeadMinutes)
        leadMinutes = [0, 1, 5, 10, 15].contains(lead) ? lead : SettingKey<Int>.calendarLeadMinutes.defaultValue
        excludedKeywords = settings.value(.calendarExclusions) ?? String(localized: "RH, entretien, médical")
        selectedCalendars = Set(settings.value(.calendarSelection))
        super.init()
    }
    func start() {
        guard allowed, !active else { return }
        active = true
        // Legacy clicks suppressed an occurrence even after its recording was deleted.
        // Calendar reminders are independent of capture history.
        settings.remove(.calendarHandled)
        center.delegate = self
        let join = UNNotificationAction(identifier: "join-record", title: String(localized: "Rejoindre et enregistrer"), options: [.foreground])
        let record = UNNotificationAction(identifier: "record", title: String(localized: "Enregistrer la réunion"), options: [.foreground])
        let recordOnly = UNNotificationAction(identifier: "record", title: String(localized: "Enregistrer sans rejoindre"), options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "meeting-online", actions: [join, recordOnly], intentIdentifiers: []),
            UNNotificationCategory(identifier: "meeting-room", actions: [record], intentIdentifiers: [])
        ])
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }
    func suspend() {
        active = false; revision += 1; timer?.invalidate(); timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        upcoming = []; calendars = []; eventStore = nil
        guard allowed else { return }
        clearReminders()
    }
    func connect() async {
        guard allowed, active, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let store = eventStore ?? EKEventStore(); eventStore = store
            guard try await store.requestFullAccessToEvents() else { status = String(localized: "Accès refusé. Autorisez HWYD dans Confidentialité et sécurité → Calendriers."); return }
            guard active else { return }
            enabled = true; settings.set(true, for: .calendarEnabled)
            await refresh()
        } catch { status = String(localized: "Calendrier : \(error.localizedDescription)") }
    }
    func saveSettings() {
        guard allowed, active else { return }
        revision += 1
        settings.set(enabled, for: .calendarEnabled)
        settings.set(reminders, for: .calendarReminders)
        settings.set(leadMinutes, for: .calendarLeadMinutes)
        settings.set(excludedKeywords, for: .calendarExclusions)
        settings.set(Array(selectedCalendars), for: .calendarSelection)
        clearReminders()
        Task { await refresh() }
    }
    func enableReminders() async {
        guard allowed, active, !busy else { return }
        busy = true; defer { busy = false }
        do {
            reminders = try await center.requestAuthorization(options: [.alert, .sound])
            guard active else { return }
            saveSettings(); await refresh()
        } catch { notificationStatus = error.localizedDescription }
    }
    private func clearReminders() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
    private func events(now: Date) -> [CalendarContext] {
        guard enabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let store = eventStore ?? EKEventStore(); eventStore = store
        let all = store.calendars(for: .event)
        calendars = all.map { .init(id: $0.calendarIdentifier, title: $0.title, account: $0.source.title) }
        let chosen = all.filter { selectedCalendars.contains($0.calendarIdentifier) }
        guard !chosen.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-86400), end: now.addingTimeInterval(7 * 86400), calendars: chosen)
        return store.events(matching: predicate).filter { event in
            !event.isAllDay && event.status != .canceled && event.endDate > now &&
            !(event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined } &&
            !MeetingRules.isExcluded(title: event.title ?? "", keywords: excludedKeywords)
        }.map { event in
            let identity = "\(event.calendar.calendarIdentifier)|\(event.calendarItemIdentifier)|\(event.startDate.timeIntervalSince1970)"
            let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let text = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
            let participants = (event.attendees ?? []).map { person in
                let email = person.url.scheme?.lowercased() == "mailto" ? String(person.url.absoluteString.dropFirst(7)).components(separatedBy: "?")[0].removingPercentEncoding : nil
                return CalendarParticipant(name: person.name, email: email)
            }
            return CalendarContext(id: id, title: event.title ?? String(localized: "Réunion"), start: event.startDate, end: event.endDate,
                calendarTitle: event.calendar.title, details: event.notes, location: event.location,
                meetingURL: MeetingRules.meetingURL(in: text), participants: participants)
        }.sorted { $0.start < $1.start }
    }
    func refresh() async {
        guard allowed, active, !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        let version = revision
        guard enabled else { upcoming = []; status = String(localized: "Non connecté"); clearReminders(); return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            upcoming = []; calendars = []; status = String(localized: "Accès calendrier requis dans les réglages macOS."); clearReminders(); return
        }
        upcoming = events(now: Date())
        status = calendars.isEmpty ? String(localized: "Aucun calendrier. Ajoutez votre compte Google dans Calendrier → Ajouter un compte.") : selectedCalendars.isEmpty ? String(localized: "Choisissez les calendriers à suivre.") : String(localized: "\(upcoming.count) réunion(s) dans les 7 prochains jours")
        let settings = await center.notificationSettings()
        guard active, version == revision else { return }
        notificationStatus = settings.authorizationStatus == .authorized ? String(localized: "Notifications autorisées") : String(localized: "Notifications non autorisées dans macOS")
        guard reminders, settings.authorizationStatus == .authorized else { clearReminders(); return }
        let now = Date()
        let scheduled = Array(upcoming.compactMap { event -> (CalendarContext, Date)? in
            guard let date = MeetingRules.reminderDate(start: event.start, minutes: leadMinutes, now: now) else { return nil }
            return (event, date)
        }.prefix(48))
        let ids = Set(scheduled.map { Self.prefix + $0.0.id })
        // Keep already delivered reminders out of the queue; the stable occurrence ID prevents duplicates.
        let pending = await center.pendingNotificationRequests()
        guard active, version == revision else { return }
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) && !ids.contains($0) })
        for (event, date) in scheduled {
            let id = Self.prefix + event.id
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Une réunion va commencer")
            content.body = String(localized: "À \(event.start.formatted(date: .omitted, time: .shortened)). Ouvrez HWYD pour voir les détails.")
            content.sound = .default
            content.categoryIdentifier = event.meetingURL == nil ? "meeting-room" : "meeting-online"
            content.userInfo = ["meetingID": event.id]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
            do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) }
            catch { notificationStatus = String(localized: "Rappel impossible : \(error.localizedDescription)") }
            guard active, version == revision else { clearReminders(); return }
        }
    }
    func sendTestReminder() async {
        guard allowed, active, reminders else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "HWYD · Rappel de test")
        content.body = String(localized: "Les rappels sont prêts. Ce test ne démarre aucun enregistrement.")
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: "hwyd.test", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
            notificationStatus = String(localized: "Rappel de test envoyé pour dans 3 secondes.")
        } catch { notificationStatus = String(localized: "Test impossible : \(error.localizedDescription)") }
    }
    /// `join` opens the event's video link before recording; otherwise HWYD only records.
    func activate(_ id: String, join: Bool = true) {
        guard allowed, active, enabled else { return }
        // Never trust the notification payload for a URL, nor a stale/cancelled occurrence.
        guard let event = events(now: Date()).first(where: { $0.id == id }) else {
            status = String(localized: "Cette réunion n’est plus disponible ou a été déplacée."); onAction?(nil, false); return
        }
        center.removeDeliveredNotifications(withIdentifiers: [Self.prefix + id])
        // Opening or recording an event does not dismiss its future calendar reminder.
        onAction?(event, join)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["meetingID"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            if ["join-record", "record"].contains(action), let id { self.activate(id, join: action == "join-record") }
            else if action == UNNotificationDefaultActionIdentifier { self.onAction?(nil, false) }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
