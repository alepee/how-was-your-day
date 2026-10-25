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
    @Published var status = "Non connecté"
    @Published var notificationStatus = "Notifications non activées"
    @Published var busy = false
    var onAction: ((CalendarContext?) -> Void)?
    private let preferences: UserDefaults
    private let allowed: Bool
    private var active = false
    private var eventStore: EKEventStore?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var refreshing = false
    private var revision = 0
    private var handled: [String: Double] = [:]
    private var center: UNUserNotificationCenter { .current() }
    static let prefix = "hwyd.meeting."
    struct CalendarChoice: Identifiable { var id: String; var title: String; var account: String }

    init(preferences: UserDefaults = .standard, allowed: Bool = false) {
        self.preferences = preferences; self.allowed = allowed
        enabled = allowed && preferences.bool(forKey: "calendar.enabled")
        reminders = allowed && preferences.bool(forKey: "calendar.reminders")
        leadMinutes = [0, 1, 5, 10, 15].contains(preferences.integer(forKey: "calendar.lead")) && preferences.object(forKey: "calendar.lead") != nil ? preferences.integer(forKey: "calendar.lead") : 5
        excludedKeywords = preferences.string(forKey: "calendar.exclusions") ?? "RH, entretien, médical"
        selectedCalendars = Set(preferences.stringArray(forKey: "calendar.selected") ?? [])
        handled = preferences.dictionary(forKey: "calendar.handled") as? [String: Double] ?? [:]
        super.init()
    }
    func start() {
        guard allowed, !active else { return }
        active = true
        center.delegate = self
        let join = UNNotificationAction(identifier: "join-record", title: "Rejoindre et enregistrer", options: [.foreground])
        let record = UNNotificationAction(identifier: "record", title: "Enregistrer la réunion", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "meeting-online", actions: [join], intentIdentifiers: []),
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
            guard try await store.requestFullAccessToEvents() else { status = "Accès refusé. Autorisez HWYD dans Confidentialité et sécurité → Calendriers."; return }
            guard active else { return }
            enabled = true; preferences.set(true, forKey: "calendar.enabled")
            await refresh()
        } catch { status = "Calendrier : \(error.localizedDescription)" }
    }
    func saveSettings() {
        guard allowed, active else { return }
        revision += 1
        preferences.set(enabled, forKey: "calendar.enabled")
        preferences.set(reminders, forKey: "calendar.reminders")
        preferences.set(leadMinutes, forKey: "calendar.lead")
        preferences.set(excludedKeywords, forKey: "calendar.exclusions")
        preferences.set(Array(selectedCalendars), forKey: "calendar.selected")
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
            return CalendarContext(id: id, title: event.title ?? "Réunion", start: event.startDate, end: event.endDate,
                calendarTitle: event.calendar.title, details: event.notes, location: event.location,
                meetingURL: MeetingRules.meetingURL(in: text), participants: participants)
        }.sorted { $0.start < $1.start }
    }
    func refresh() async {
        guard allowed, active, !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        let version = revision
        guard enabled else { upcoming = []; status = "Non connecté"; clearReminders(); return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            upcoming = []; calendars = []; status = "Accès calendrier requis dans les réglages macOS."; clearReminders(); return
        }
        upcoming = events(now: Date())
        status = calendars.isEmpty ? "Aucun calendrier. Ajoutez votre compte Google dans Calendrier → Ajouter un compte." : selectedCalendars.isEmpty ? "Choisissez les calendriers à suivre." : "\(upcoming.count) réunion(s) dans les 7 prochains jours"
        let settings = await center.notificationSettings()
        guard active, version == revision else { return }
        notificationStatus = settings.authorizationStatus == .authorized ? "Notifications autorisées" : "Notifications non autorisées dans macOS"
        guard reminders, settings.authorizationStatus == .authorized else { clearReminders(); return }
        let now = Date()
        handled = handled.filter { $0.value > now.timeIntervalSince1970 }
        preferences.set(handled, forKey: "calendar.handled")
        let scheduled = Array(upcoming.compactMap { event -> (CalendarContext, Date)? in
            guard handled[event.id] == nil, let date = MeetingRules.reminderDate(start: event.start, minutes: leadMinutes, now: now) else { return nil }
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
            content.title = "Une réunion va commencer"
            content.body = "À \(event.start.formatted(date: .omitted, time: .shortened)). Ouvrez HWYD pour voir les détails."
            content.sound = .default
            content.categoryIdentifier = event.meetingURL == nil ? "meeting-room" : "meeting-online"
            content.userInfo = ["meetingID": event.id]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
            do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) }
            catch { notificationStatus = "Rappel impossible : \(error.localizedDescription)" }
            guard active, version == revision else { clearReminders(); return }
        }
    }
    func sendTestReminder() async {
        guard allowed, active, reminders else { return }
        let content = UNMutableNotificationContent()
        content.title = "HWYD · Rappel de test"
        content.body = "Les rappels sont prêts. Ce test ne démarre aucun enregistrement."
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: "hwyd.test", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
            notificationStatus = "Rappel de test envoyé pour dans 3 secondes."
        } catch { notificationStatus = "Test impossible : \(error.localizedDescription)" }
    }
    func activate(_ id: String) {
        guard allowed, active, enabled else { return }
        // Never trust the notification payload for a URL, nor a stale/cancelled occurrence.
        guard let event = events(now: Date()).first(where: { $0.id == id }) else {
            status = "Cette réunion n’est plus disponible ou a été déplacée."; onAction?(nil); return
        }
        center.removeDeliveredNotifications(withIdentifiers: [Self.prefix + id])
        center.removePendingNotificationRequests(withIdentifiers: [Self.prefix + id])
        handled[id] = event.end.timeIntervalSince1970
        preferences.set(handled, forKey: "calendar.handled")
        onAction?(event)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["meetingID"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            if ["join-record", "record"].contains(action), let id { self.activate(id) }
            else if action == UNNotificationDefaultActionIdentifier { self.onAction?(nil) }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
