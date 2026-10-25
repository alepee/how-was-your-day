import SwiftUI
import HWYDCore

struct CalendarSettingsView: View {
    @ObservedObject var calendar: CalendarIntegration
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("CALENDRIERS ET RAPPELS", systemImage: "calendar").font(.system(size: 10, weight: .medium)).foregroundStyle(Studio.mint)
            Text("Google Calendar via macOS").font(.system(size: 14, weight: .medium))
            Text("Ajoutez votre compte Google dans l’app Calendrier → Ajouter un compte, puis autorisez HWYD. Les comptes Apple et Outlook synchronisés sont aussi disponibles. Aucun événement n’est modifié.")
                .font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            Text(calendar.status).font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(calendar.busy ? "Connexion…" : "Autoriser les calendriers") { Task { await calendar.connect() } }.disabled(calendar.busy)
                Button("Actualiser") { Task { await calendar.refresh() } }
            }.buttonStyle(StudioButtonStyle())
            if calendar.enabled {
                Toggle("Suivre les calendriers sélectionnés", isOn: Binding(get: { calendar.enabled }, set: { calendar.enabled = $0; calendar.saveSettings() }))
                ForEach(calendar.calendars) { item in
                    Toggle("\(item.title) · \(item.account)", isOn: Binding(get: { calendar.selectedCalendars.contains(item.id) }, set: { enabled in
                        if enabled { calendar.selectedCalendars.insert(item.id) } else { calendar.selectedCalendars.remove(item.id) }
                        calendar.saveSettings()
                    })).font(.system(size: 11))
                }
                TextField("Mots-clés exclus, séparés par des virgules", text: $calendar.excludedKeywords)
                    .textFieldStyle(.roundedBorder).onSubmit { calendar.saveSettings() }
                Button("Appliquer les exclusions") { calendar.saveSettings() }.buttonStyle(StudioButtonStyle())
                Text("Exclusions sur le titre. Journées entières, événements annulés et invitations refusées sont ignorés.").font(.system(size: 10)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                Toggle("Rappeler avant les réunions", isOn: Binding(get: { calendar.reminders }, set: { value in
                    if value { Task { await calendar.enableReminders() } }
                    else { calendar.reminders = false; calendar.saveSettings() }
                })).disabled(calendar.busy)
                Picker("Prévenir", selection: Binding(get: { calendar.leadMinutes }, set: { calendar.leadMinutes = $0; calendar.saveSettings() })) {
                    Text("Au début").tag(0)
                    ForEach([1, 5, 10, 15], id: \.self) { Text("\($0) min avant").tag($0) }
                }
                Button("Tester une notification") { Task { await calendar.sendTestReminder() } }
                    .buttonStyle(StudioButtonStyle()).disabled(!calendar.reminders)
                Text(calendar.notificationStatus).font(.system(size: 11)).foregroundStyle(Studio.muted)
                Text("Le clic « Rejoindre et enregistrer » ouvre la visio et lance la capture. Sans clic, aucun enregistrement. Les rappels des 7 prochains jours sont préparés tant que HWYD tourne ; un rappel peut s’afficher après sa fermeture.")
                    .font(.system(size: 10)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Studio.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}
struct UpcomingMeetingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var calendar: CalendarIntegration
    var body: some View {
        if calendar.enabled {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "À venir")
                if calendar.upcoming.isEmpty { Text(calendar.status).font(.system(size: 12)).foregroundStyle(Studio.muted) }
                ForEach(Array(calendar.upcoming.prefix(4))) { event in
                    HStack(spacing: 14) {
                        Image(systemName: "calendar").foregroundStyle(Studio.mint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                            Text("\(event.start.formatted(date: .abbreviated, time: .shortened)) · \(event.calendarTitle)").font(.system(size: 10)).foregroundStyle(Studio.muted)
                        }
                        Spacer()
                        Button(event.meetingURL == nil ? "Enregistrer" : "Rejoindre et enregistrer") { calendar.activate(event.id) }
                            .buttonStyle(StudioButtonStyle()).disabled(model.activeCaptureID != nil || model.isStarting)
                    }.padding(14).background(Studio.surface, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
