import Foundation

/// The language the user chose for HWYD. It sets the interface and everything HWYD writes:
/// summaries and their exports, labels it gives new voices, examples.
///
/// The choice is stored where macOS keeps a per-app language (`AppleLanguages` in the app's
/// domain, the same value System Settings › Language & Region writes), so the interface,
/// `Bundle.hwyd` and the helpers resolve it the same way. It applies at the next launch.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    /// Follows the macOS language order: English when English comes before French, French otherwise.
    case system
    case french = "fr"
    case english = "en"

    public var id: String { rawValue }

    /// Reads the choice from the per-app language list. A language HWYD is not translated into reads as `system`.
    public init(appleLanguages: [String]?) {
        switch appleLanguages?.first.map(SpeechLanguage.languageCode) {
        case "fr": self = .french
        case "en": self = .english
        default: self = .system
        }
    }

    /// The per-app language list for this choice. Nil removes it, so macOS decides.
    public var appleLanguages: [String]? {
        switch self {
        case .system: nil
        case .french: ["fr"]
        case .english: ["en"]
        }
    }

    /// Name shown in the picker, each language in its own language.
    public var title: String {
        switch self {
        case .system: String(localized: "Langue du système", bundle: .hwyd)
        case .french: "Français" // l10n:ignore (endonym)
        case .english: "English" // l10n:ignore (endonym)
        }
    }
}

extension SettingKey where Value == [String]? {
    /// Per-app language list, read by macOS at launch. Written only through `AppLanguage`.
    public static var appleLanguages: Self { .init("AppleLanguages", default: nil) }
}

extension SummaryLanguage {
    /// The language HWYD writes in: the localization the app resolved for itself, passed to helpers.
    public static var current: SummaryLanguage { SpeechLanguage.languageCode(of: HWYDLocalization.current) == "en" ? .english : .french }

    /// BCP 47 language code stored in summary provenance.
    public var code: String { self == .english ? "en" : "fr" }
    public init(code: String?) { self = code.map(SpeechLanguage.languageCode) == "en" ? .english : .french }

    var locale: Locale { Locale(identifier: self == .english ? "en_US" : "fr_FR") }

    /// Label HWYD gives a new voice found in a session. Stored with the session: it keeps the language it was written in.
    public func voiceLabel(_ number: Int) -> String { (self == .english ? "Voice " : "Voix ") + String(number) } // l10n:ignore (stored label)
    /// Label of a voice that gave back the identity it had lent when merged. Stored like `voiceLabel`.
    public var voiceToName: String { self == .english ? "Voice to name" : "Voix à nommer" } // l10n:ignore (stored label)
    /// Label shared by the voices too brief to be named. Stored like `voiceLabel`.
    public var otherVoice: String { self == .english ? "Other voice" : "Autre voix" } // l10n:ignore (stored label)
    /// Speaker name sent to models for a passage without a voice.
    public var unidentifiedSpeaker: String { self == .english ? "Unidentified voice" : "Voix non identifiée" } // l10n:ignore (model-facing)
}

/// Words of a summary document, in the language the summary was written in. Kept apart from the
/// interface catalog: a summary keeps its language when the user changes theirs.
public struct SummaryVocabulary: Sendable {
    public let language: SummaryLanguage
    public init(_ language: SummaryLanguage) { self.language = language }
    private var english: Bool { language == .english }

    public func heading(_ section: SummarySection) -> String? {
        switch section {
        case .overview: english ? "Overview" : "Résumé" // l10n:ignore
        case .keyPoints: nil
        case .decisions: english ? "Decisions" : "Décisions" // l10n:ignore
        case .actions: english ? "Next steps" : "Étapes suivantes" // l10n:ignore
        case .details: english ? "Details" : "Détails" // l10n:ignore
        case .context: english ? "Context" : "Contexte" // l10n:ignore
        }
    }
    public var sources: String { english ? "Sources: " : "Sources : " } // l10n:ignore
    public var participants: String { english ? "Participants: " : "Participants : " } // l10n:ignore
    public var assigneeSeparator: String { english ? ": " : " : " } // l10n:ignore
    public var summary: String { english ? "Summary" : "Synthèse" } // l10n:ignore
    public var fileSuffix: String { english ? " - summary" : " - synthèse" } // l10n:ignore
    public var draft: String { english ? "Draft to review" : "Brouillon à relire" } // l10n:ignore
    public var example: String { english ? "Fictional summary · example" : "Synthèse fictive · exemple" } // l10n:ignore
    public var staleNotice: String { english ? "The transcript has changed since this summary." : "Le transcript a changé depuis cette synthèse." } // l10n:ignore
    public var generatedByModel: String { english ? "Summary generated by a model, to review." : "Synthèse générée par un modèle, à relire." } // l10n:ignore
    public func generated(by model: String, on date: String, review: Bool) -> String {
        english ? "Summary generated by " + model + " on " + date + (review ? ", to review." : "") // l10n:ignore
            : "Synthèse générée par " + model + " le " + date + (review ? ", à relire." : "") // l10n:ignore
    }
    /// Singular and plural nouns of the counts shown under the overview.
    public var decisionNoun: (String, String) { english ? ("decision", "decisions") : ("décision", "décisions") } // l10n:ignore
    public var actionNoun: (String, String) { ("action", "actions") }
    public var topicNoun: (String, String) { english ? ("topic", "topics") : ("thème", "thèmes") } // l10n:ignore
    public func date(_ value: Date, style: Date.FormatStyle.DateStyle = .long, time: Date.FormatStyle.TimeStyle = .shortened) -> String {
        value.formatted(Date.FormatStyle(date: style, time: time).locale(language.locale))
    }
}
