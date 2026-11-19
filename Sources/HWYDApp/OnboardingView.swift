import SwiftUI
import HWYDCore

/// The welcome tour, shown over the app: one feature per step, with the control that turns it on.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var guide: OnboardingGuide
    var body: some View {
        VStack(spacing: 0) {
            OnboardingIllustration(step: guide.step)
            // A steady height for short steps; a step with more content (many agents or calendars) grows the card downward.
            OnboardingStepView(step: guide.step).id(guide.step)
                .frame(maxWidth: .infinity, minHeight: Self.minContentHeight, alignment: .top)
                .padding(.horizontal, 40).padding(.top, 4).padding(.bottom, 20)
            ZStack {
                // The dots stay centered whatever the buttons on either side.
                HStack(spacing: 6) {
                    ForEach(OnboardingStep.allCases, id: \.self) { step in
                        Circle().fill(step == guide.step ? Studio.mint : Studio.line).frame(width: 6, height: 6)
                    }
                }.accessibilityHidden(true)
                HStack(spacing: 10) {
                    Button("Passer") { guide.finish() }.buttonStyle(.plain)
                        .font(.system(size: Studio.Size.body)).foregroundStyle(Studio.muted).keyboardShortcut(.cancelAction)
                    Spacer()
                    if guide.step.previous != nil {
                        Button { guide.goBack() } label: { Image(systemName: "arrow.left") }.buttonStyle(StudioButtonStyle())
                            .accessibilityLabel("Retour")
                    }
                    Button { guide.advance() } label: {
                        Text(guide.step.next == nil ? String(localized: "Terminer") : String(localized: "Continuer")).frame(minWidth: 70)
                    }.buttonStyle(StudioButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 560).fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(Studio.text).background(Studio.background)
    }
    /// Banner and footer aside, so that the shortest step makes a card of about 500 points.
    static let minContentHeight: CGFloat = 256
}

private struct OnboardingStepView: View {
    @EnvironmentObject var model: AppModel
    let step: OnboardingStep
    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.system(size: Studio.Size.title, weight: .semibold)).tracking(-0.7).multilineTextAlignment(.center)
            Text(text).font(.system(size: Studio.Size.heading)).foregroundStyle(Studio.muted).lineSpacing(4)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
            action.padding(.top, 14)
        }
    }
    private var title: String {
        switch step {
        case .record: String(localized: "Enregistrez n’importe quelle réunion")
        case .calendar: String(localized: "Vos réunions, au bon moment")
        case .transcription: String(localized: "Transcrite sur votre Mac")
        case .voices: String(localized: "Qui a dit quoi")
        case .summary: String(localized: "Une synthèse par votre agent")
        case .context: String(localized: "Encore mieux avec votre contexte")
        }
    }
    private var text: String {
        switch step {
        case .record: String(localized: "Visio, appel ou discussion autour de la table : HWYD enregistre votre micro et le son de l’ordinateur. Rien à installer dans la réunion.")
        case .calendar: String(localized: "HWYD lit les calendriers que vous choisissez pour vous rappeler d’enregistrer et nommer chaque session d’après sa réunion. Aucun événement n’est modifié.")
        case .transcription: String(localized: "Chaque session est transcrite après l’enregistrement, sans que l’audio quitte votre Mac.")
        case .voices: String(localized: "HWYD distingue les personnes qui parlent, pour que vous n’ayez plus qu’à les nommer.")
        case .summary: String(localized: "L’agent que vous utilisez déjà rédige les points clés, les décisions et les prochaines étapes de chaque session.")
        case .context: String(localized: "Votre agent garde vos notes ou votre mémoire dans un dossier ? Il s’en servira pour situer les personnes et les projets.")
        }
    }

    @ViewBuilder private var action: some View {
        switch step {
        case .record:
            if let shortcut = model.recordingShortcut {
                Text("\(shortcut.display) lance ou arrête un enregistrement depuis n’importe quelle app.")
                    .font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
            }
        case .calendar: OnboardingCalendars(calendar: model.calendar)
        case .transcription: transcription
        case .voices: voices
        case .summary: OnboardingAgents(settings: model.summarySettings)
        case .context: context
        }
    }
    private var transcription: some View {
        VStack(spacing: 8) {
            if let locale = model.installingSpeechLocale {
                progress(String(localized: "Installation : \(SpeechLanguage.displayName(locale))…"))
            } else if model.installedSpeechLocales.isEmpty {
                if let locale = suggestedLocale {
                    Button("Installer le modèle \(SpeechLanguage.displayName(locale))") { model.installSpeechModel(locale) }
                        .buttonStyle(StudioButtonStyle(primary: true)).disabled(!model.workAvailability.isReady)
                }
                languageMenu(String(localized: "Une autre langue"))
                Text("Environ 350 Mo, téléchargés une fois.").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
            } else {
                done(model.installedSpeechLocales.map { SpeechLanguage.displayName($0) }.joined(separator: ", "))
                languageMenu(String(localized: "Ajouter une langue"))
            }
        }.task { model.refreshSpeechLanguages() }
    }
    @ViewBuilder private var voices: some View {
        if model.isInstallingDiarizer { progress(String(localized: "Installation…")) }
        else if model.diarizerReady && model.diarizationEnabled { done(String(localized: "Activée")) }
        else if model.diarizerReady {
            Button("Activer") { model.diarizationEnabled = true }.buttonStyle(StudioButtonStyle(primary: true))
        } else {
            Button("Installer le modèle") { model.installDiarizer() }
                .buttonStyle(StudioButtonStyle(primary: true)).disabled(!model.workAvailability.isReady)
        }
    }
    @ViewBuilder private var context: some View {
        let settings = model.summarySettings
        let chosen = settings.agentDirectory != SettingKey<String>.summaryAgentDirectory.defaultValue
        VStack(spacing: 8) {
            if chosen { done(settings.agentDirectory) }
            Button(chosen ? String(localized: "Choisir un autre dossier") : String(localized: "Choisir le dossier")) { model.chooseSummaryAgentDirectory() }
                .buttonStyle(StudioButtonStyle(primary: !chosen)).disabled(settings.service != .agent || !settings.enabled)
            if settings.service != .agent || !settings.enabled {
                Text("Connectez d’abord un agent à l’étape précédente.").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
            }
        }
    }

    /// The first of the Mac's languages that Apple Speech offers.
    private var suggestedLocale: String? {
        Locale.preferredLanguages.lazy.compactMap { preferred in
            model.supportedSpeechLocales.first { SpeechLanguage.languageCode(of: $0) == SpeechLanguage.languageCode(of: preferred) }
        }.first
    }
    private func languageMenu(_ title: String) -> some View {
        let installed = Set(model.installedSpeechLocales.map(SpeechLanguage.languageCode))
        return Menu(title) {
            ForEach(model.supportedSpeechLocales.filter { !installed.contains(SpeechLanguage.languageCode(of: $0)) }, id: \.self) { locale in
                Button(SpeechLanguage.displayName(locale)) { model.installSpeechModel(locale) }
            }
        }.menuStyle(.borderlessButton).fixedSize().font(.system(size: Studio.Size.body)).disabled(!model.workAvailability.isReady)
    }
    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(text).font(.system(size: Studio.Size.body)).foregroundStyle(Studio.muted) }
    }
    private func done(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill").font(.system(size: Studio.Size.body)).foregroundStyle(Studio.mint)
            .lineLimit(1).truncationMode(.middle)
    }
}

/// The agents found on this Mac, each connected in one click. An agent whose adapter is missing
/// gets it installed first.
struct OnboardingAgents: View {
    @ObservedObject var settings: SummarySettings
    private var agents: [ACPAgentPreset] { Self.agents(in: settings) }
    static func agents(in settings: SummarySettings) -> [ACPAgentPreset] {
        ACPAgentPreset.all.filter { settings.detectedAgents.contains($0.command) || settings.installableAgents.contains($0.command) }
    }
    var body: some View {
        VStack(spacing: 6) {
            if agents.isEmpty {
                Text("Aucun agent compatible trouvé sur ce Mac. D’autres options sont dans Réglages › Synthèse.")
                    .font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).multilineTextAlignment(.center)
            }
            ForEach(agents) { agent in
                HStack {
                    Text(agent.name).font(.system(size: Studio.Size.body, weight: .medium))
                    Spacer()
                    control(for: agent)
                }.padding(.horizontal, 14).frame(width: 340, height: 40) // The same for every state of the control.
                    .background(Studio.surface, in: RoundedRectangle(cornerRadius: 8))
            }
        }.onAppear { settings.detectAgents() }
    }
    @ViewBuilder private func control(for agent: ACPAgentPreset) -> some View {
        if settings.enabled && settings.service == .agent && settings.agentCommand == agent.command {
            Label("Connecté", systemImage: "checkmark.circle.fill").font(.system(size: Studio.Size.body)).foregroundStyle(Studio.mint)
        } else if settings.installingAgent == agent.command {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installation…").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted) }
        } else if settings.detectedAgents.contains(agent.command) {
            Button("Connecter") { settings.useAgent(agent.command) }.buttonStyle(StudioButtonStyle(compact: true))
        } else {
            Button("Installer et connecter") { settings.installAndUseAgent(agent.command) }.buttonStyle(StudioButtonStyle(compact: true))
                .disabled(settings.installingAgent != nil).help(agent.adapterInstallCommand ?? "")
        }
    }
}

/// Calendar access, then the calendars to follow. Reminders and exclusions stay in the settings.
private struct OnboardingCalendars: View {
    @ObservedObject var calendar: CalendarIntegration
    var body: some View {
        VStack(spacing: 8) {
            if calendar.enabled && !calendar.calendars.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(calendar.calendars) { item in
                            Toggle(isOn: Binding(get: { calendar.selectedCalendars.contains(item.id) }, set: { on in
                                if on { calendar.selectedCalendars.insert(item.id) } else { calendar.selectedCalendars.remove(item.id) }
                                calendar.saveSettings()
                            })) {
                                Text(item.title).font(.system(size: Studio.Size.body))
                                    + Text(" · \(item.account)").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
                            }.toggleStyle(.checkbox)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 10)
                }.frame(width: 340).frame(maxHeight: 220).fixedSize(horizontal: false, vertical: true)
                    .background(Studio.surface, in: RoundedRectangle(cornerRadius: 8))
                Toggle("Me rappeler avant chaque réunion", isOn: Binding(get: { calendar.reminders }, set: { on in
                    if on { Task { await calendar.enableReminders() } } else { calendar.reminders = false; calendar.saveSettings() }
                })).toggleStyle(.switch).controlSize(.small).font(.system(size: Studio.Size.body)).disabled(calendar.busy)
                Text("Délai et mots-clés exclus : Réglages › Calendrier.").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
            } else {
                Button(calendar.busy ? String(localized: "Connexion…") : String(localized: "Autoriser les calendriers")) { Task { await calendar.connect() } }
                    .buttonStyle(StudioButtonStyle(primary: true)).disabled(calendar.busy || !calendar.isAvailable)
                Text(calendar.status).font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted).multilineTextAlignment(.center)
                Text("Comptes Google, iCloud et Outlook ajoutés à l’app Calendrier de macOS.").font(.system(size: Studio.Size.caption)).foregroundStyle(Studio.muted)
            }
        }
    }
}
