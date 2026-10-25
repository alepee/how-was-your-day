import SwiftUI
import HWYDCore

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general = "Général", calendar = "Calendrier", audio = "Audio et voix", summary = "Synthèse", data = "Données locales", integrations = "Agents et exports"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "circle.lefthalf.filled"
        case .calendar: "calendar"
        case .audio: "waveform"
        case .summary: "sparkles"
        case .data: "internaldrive"
        case .integrations: "externaldrive.connected.to.line.below"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "Personnalisez votre espace de travail."
        case .calendar: "Retrouvez vos réunions et choisissez quand recevoir un rappel."
        case .audio: "Configurez la transcription et la séparation des voix sur ce Mac."
        case .summary: "Choisissez le modèle local qui résume vos sessions."
        case .data: "Retrouvez vos fichiers et les préférences de conservation."
        case .integrations: "Partagez vos sessions avec vos outils et contrôlez leurs accès."
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 9) {
                    Eyebrow(text: "Réglages")
                    Text(model.settingsCategory.rawValue).font(.system(size: 28, weight: .semibold))
                    Text(model.settingsCategory.subtitle).font(.system(size: 12)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button { model.showSettings = false } label: { Label("Retour", systemImage: "arrow.left") }
                    .buttonStyle(StudioButtonStyle()).accessibilityLabel("Revenir à la session ou à la bibliothèque")
            }.padding(30)
            Rectangle().fill(Studio.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content
                }.frame(maxWidth: 820, alignment: .leading).padding(30).frame(maxWidth: .infinity, alignment: .leading)
            }.id(model.settingsCategory)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onDisappear { model.saveSummarySettings() }
    }
    @ViewBuilder private var content: some View {
        switch model.settingsCategory {
        case .general:
            section("APPARENCE", symbol: "circle.lefthalf.filled") {
                Picker("Thème", selection: $model.appearancePreference) {
                    ForEach(AppearancePreference.allCases) { preference in Text(preference.title).tag(preference) }
                }.pickerStyle(.segmented)
                Text("Système suit automatiquement l’apparence de macOS.").font(.system(size: 11)).foregroundStyle(Studio.muted)
            }
            section("DÉCOUVRIR HWYD", symbol: "rectangle.stack") {
                Text("Explorez l’interface avec des sessions fictives, sans utiliser le micro.").font(.system(size: 12)).foregroundStyle(Studio.muted)
                Button(model.isDemoMode ? "Quitter les exemples" : "Explorer des exemples") {
                    model.showSettings = false
                    if model.isDemoMode { model.leaveDemo() } else { model.enterDemo() }
                }.buttonStyle(StudioButtonStyle()).disabled(model.pipelineBusy || model.activeCaptureID != nil || model.hasUnsavedChanges)
            }
        case .calendar:
            CalendarSettingsView(calendar: model.calendar).disabled(model.isDemoMode)
        case .audio:
            section("CAPTURE", symbol: "waveform") {
                Text("Micro brut + audio système").font(.system(size: 14, weight: .medium))
                Text("Deux pistes séparées, sans traitement de voix. Aucun démarrage automatique.").font(.system(size: 12)).foregroundStyle(Studio.muted).lineSpacing(4)
            }
            section("TRANSCRIPTION", symbol: "text.bubble") {
                Text("Français · Apple Speech · traitement local").font(.system(size: 12))
                Text("L’installation peut télécharger le modèle Apple. Aucun audio n’est envoyé pour la transcription.").font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                Button(model.isInstallingModel ? "Installation en cours…" : "Installer le modèle français") { model.installSpeechModel() }
                    .buttonStyle(StudioButtonStyle()).disabled(model.pipelineBusy || model.isDemoMode)
            }
            section("SÉPARATION DES VOIX", symbol: "person.2.wave.2") {
                Toggle("Séparer les voix après transcription", isOn: $model.diarizationEnabled).disabled(model.pipelineBusy || model.isDemoMode)
                Text("Community-1 · traitement local par piste. Les modèles se téléchargent une fois ; aucune empreinte personnelle n’est créée sans enrôlement explicite.").font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                Button(model.isInstallingDiarizer ? "Installation des voix…" : "Installer les modèles de voix") { model.installDiarizer() }
                    .buttonStyle(StudioButtonStyle()).disabled(model.pipelineBusy || model.isDemoMode)
            }
        case .summary:
            section("SYNTHÈSE LOCALE", symbol: "sparkles") {
                Toggle("Activer la synthèse locale", isOn: $model.summaryEnabled).onChange(of: model.summaryEnabled) { _, _ in model.saveSummarySettings() }
                Text("Adresse du serveur local").font(.system(size: 12, weight: .medium))
                TextField("http://127.0.0.1:1234/v1", text: $model.summaryEndpoint).textFieldStyle(.roundedBorder)
                Text("Modèle chargé").font(.system(size: 12, weight: .medium))
                TextField("Identifiant du modèle", text: $model.summaryModel).textFieldStyle(.roundedBorder)
                Button("Enregistrer le modèle") { model.saveSummarySettings() }.buttonStyle(StudioButtonStyle())
                Text("LM Studio ou Ollama, API OpenAI-compatible et JSON Schema requis. Seules les adresses de boucle locale sont acceptées. Chaque synthèse est lancée manuellement depuis la session.").font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
            }.disabled(model.isDemoMode)
        case .data:
            section("DONNÉES LOCALES", symbol: "internaldrive") {
                HStack { Text("Rétention audio souhaitée"); Spacer(); Picker("Rétention", selection: $model.retentionHours) { Text("24 heures").tag(24); Text("72 heures").tag(72); Text("7 jours").tag(168) }.labelsHidden().frame(width: 145) }.font(.system(size: 12))
                Text("Préférence enregistrée. La purge automatique attend l’intégration du pipeline ; aucun audio n’est supprimé automatiquement dans cette version.").font(.system(size: 11)).foregroundStyle(Studio.copper).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                Button("Ouvrir le dossier de données") { NSWorkspace.shared.open(model.dataDirectory) }.buttonStyle(StudioButtonStyle())
            }
        case .integrations:
            section("AGENTS ET EXPORTS", symbol: "externaldrive.connected.to.line.below") {
                Toggle("Autoriser les agents à modifier notes et noms", isOn: Binding(get: { model.mcpWritesEnabled }, set: { model.setMCPWrites($0) }))
                Text("MCP reste en lecture seule par défaut. Les écritures exigent aussi --allow-write au lancement du serveur.").font(.system(size: 11)).foregroundStyle(Studio.muted).fixedSize(horizontal: false, vertical: true)
                Button("Choisir le dossier de publication…") { model.chooseExportDirectory() }.buttonStyle(StudioButtonStyle())
                if !model.exportDirectory.isEmpty { Text(model.exportDirectory).font(.system(size: 10)).foregroundStyle(Studio.muted).textSelection(.enabled) }
            }.disabled(model.isDemoMode)
        }
    }
    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) { Image(systemName: symbol).foregroundStyle(Studio.mint); Eyebrow(text: title) }
            content()
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(Studio.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}
