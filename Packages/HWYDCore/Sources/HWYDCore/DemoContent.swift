import Foundation

/// Fictional sessions of the example library, written in the user's language.
public enum DemoContent {
    public static func recordings(now: Date = Date(), language: SummaryLanguage = .current) -> [Recording] {
        let t = language == .english ? Text.english : Text.french
        let me = Speaker(label: t.you, confirmed: true)
        let camille = Speaker(label: "Camille", confirmed: true, source: .system)
        let unknown = Speaker(label: language.voiceLabel(3), source: .system)
        let today = Calendar.current.startOfDay(for: now)
        var recordings = [Recording(title: t.meetingTitle, kind: .meeting, startedAt: today.addingTimeInterval(36_000), duration: 1934, state: .demo,
            notes: t.meetingNotes,
            noteEntries: [.init(offset: 190, text: t.noteEntries[0]), .init(offset: 765, text: t.noteEntries[1])],
            speakers: [me, camille, unknown], segments: [
                .init(start: 12, end: 19, speakerID: me.id, source: .mic, text: t.segments[0]),
                .init(start: 21, end: 34, speakerID: camille.id, source: .system, text: t.segments[1]),
                .init(start: 38, end: 46, speakerID: unknown.id, source: .system, text: t.segments[2]),
                .init(start: 49, end: 62, speakerID: me.id, source: .mic, text: t.segments[3]),
                .init(start: 66, end: 78, speakerID: camille.id, source: .system, text: t.segments[4])
            ], isDemo: true),
            Recording(title: t.memoTitle, kind: .voiceMemo, startedAt: today.addingTimeInterval(31_320), duration: 248, state: .demo, notes: t.memoNotes, speakers: [me], segments: [.init(start: 2, end: 12, speakerID: me.id, source: .mic, text: t.memoSegment)], isDemo: true),
            Recording(title: t.coffeeTitle, kind: .exchange, startedAt: today.addingTimeInterval(29_700), duration: 1102, state: .demo, notes: t.coffeeNotes, isDemo: true),
            Recording(title: t.callTitle, kind: .exchange, startedAt: today.addingTimeInterval(-27_000), duration: 1462, state: .demo, notes: t.callNotes, isDemo: true)
        ]
        let ids = recordings[0].segments.map(\.id)
        var summary = SummaryContent(overview: t.overview, decisions: [.init(text: t.decision, evidence_segment_ids: [ids[0], ids[1]])], action_items: [.init(text: t.action, assignee_name: "Camille", assignee_person_id: nil, due_date: nil, evidence_segment_ids: [ids[1]])])
        summary.key_points = [.init(title: t.keyPoint.0, text: t.keyPoint.1, evidence_segment_ids: [ids[0], ids[1]])]
        summary.details = [
            .init(title: t.details[0].0, text: t.details[0].1, evidence_segment_ids: [ids[0], ids[1]]),
            .init(title: t.details[1].0, text: t.details[1].1, evidence_segment_ids: [ids[2], ids[3], ids[4]])
        ]
        let provenance = SummaryProvenance(provider: "fixture", model: "fixture", promptVersion: "summary-v4", promptHash: "fixture", generatedAt: now, transcriptVersion: 1, inputHash: "fixture", structured: summary, language: language.code)
        recordings[0].summary = provenance.markdown
        recordings[0].summaryProvenance = provenance
        return recordings
    }

    private struct Text {
        let you, meetingTitle, meetingNotes: String
        let noteEntries, segments: [String]
        let memoTitle, memoNotes, memoSegment, coffeeTitle, coffeeNotes, callTitle, callNotes: String
        let overview, decision, action: String
        let keyPoint: (String, String)
        let details: [(String, String)]

        static let french = Text(
            you: "Vous", meetingTitle: "Le prochain chapitre",
            meetingNotes: "Simplifier le premier lancement.\n\nUne session doit pouvoir commencer sans calendrier. Prévoir une correction des voix directement depuis le transcript.",
            noteEntries: ["Garder le démarrage en un clic.", "Revoir le parcours de correction des voix."],
            segments: ["Je veux pouvoir enregistrer une idée sans créer une réunion. Le calendrier doit rester un contexte, pas un passage obligé.",
                       "Alors on commence par un bouton, et on ajoute le contexte ensuite. Je peux préparer deux parcours de premier lancement pour comparer.",
                       "Et les notes prises pendant la discussion doivent rester au même endroit. C’est souvent là qu’on retrouve la décision, pas dans le résumé.",
                       "Oui. On garde les notes, le transcript et l’audio ensemble, avec une correction simple quand une voix n’est pas reconnue.",
                       "On teste avec une vraie conversation en salle avant d’aller plus loin. Les voix éloignées sont le cas le plus difficile."],
            memoTitle: "Une idée en marchant", memoNotes: "Et si le meilleur résumé était simplement la phrase qu’on a notée soi-même ?",
            memoSegment: "Je pense à une interface qui s’efface pendant qu’on parle. Un bouton pour démarrer, et une page pour ce qui compte.",
            coffeeTitle: "Café avec Léa", coffeeNotes: "Reprendre la discussion sur l’atelier de jeudi.",
            callTitle: "Retour sur le prototype", callNotes: "Donner plus de place au transcript, sans masquer les notes.",
            overview: "L’équipe définit un premier lancement simple et une relecture qui rassemble audio, transcript et notes.",
            decision: "Permettre de démarrer sans événement calendrier.", action: "Préparer deux parcours de premier lancement.",
            keyPoint: ("Démarrage immédiat", "Un bouton suffit, le contexte peut être ajouté ensuite."),
            details: [("Un calendrier facultatif", "Une idée doit pouvoir être enregistrée sans créer de réunion. Camille propose un démarrage par un seul bouton et l’ajout du contexte ensuite. Deux parcours permettront de comparer le premier lancement."),
                      ("Retrouver le contexte et corriger les voix", "Les notes prises pendant la discussion restent avec l’audio et le transcript. Une correction simple doit permettre de rectifier une voix mal reconnue. Un test en salle est proposé, car les voix éloignées sont plus difficiles à distinguer.")])

        static let english = Text(
            you: "You", meetingTitle: "The next chapter",
            meetingNotes: "Simplify the first launch.\n\nA session must be able to start without a calendar. Plan to correct voices right from the transcript.",
            noteEntries: ["Keep the one-click start.", "Review the voice correction flow."],
            segments: ["I want to record an idea without creating a meeting. The calendar should stay context, not a required step.",
                       "Then we start with a button and add the context afterwards. I can prepare two first-launch flows to compare.",
                       "And the notes taken during the discussion should stay in the same place. That’s often where you find the decision, not in the summary.",
                       "Yes. We keep the notes, the transcript and the audio together, with a simple correction when a voice isn’t recognized.",
                       "Let’s test with a real conversation in a room before going further. Distant voices are the hardest case."],
            memoTitle: "An idea on a walk", memoNotes: "What if the best summary were simply the sentence you wrote down yourself?",
            memoSegment: "I’m thinking of an interface that fades away while you talk. One button to start, and one page for what matters.",
            coffeeTitle: "Coffee with Léa", coffeeNotes: "Pick up the discussion about Thursday’s workshop.",
            callTitle: "Prototype feedback", callNotes: "Give the transcript more room without hiding the notes.",
            overview: "The team defines a simple first launch and a review that brings audio, transcript and notes together.",
            decision: "Allow starting without a calendar event.", action: "Prepare two first-launch flows.",
            keyPoint: ("Immediate start", "One button is enough; context can be added afterwards."),
            details: [("An optional calendar", "An idea must be recordable without creating a meeting. Camille suggests starting with a single button and adding the context afterwards. Two flows will make it possible to compare the first launch."),
                      ("Finding context and correcting voices", "Notes taken during the discussion stay with the audio and the transcript. A simple correction should fix a misrecognized voice. A test in a room is suggested, because distant voices are harder to tell apart.")])
    }
}
