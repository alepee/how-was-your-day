import Foundation

public enum DemoContent {
    public static func recordings(now: Date = Date()) -> [Recording] {
        let me = Speaker(label: "Vous", confirmed: true)
        let camille = Speaker(label: "Camille", confirmed: true, source: .system)
        let unknown = Speaker(label: "Speaker 3", source: .system)
        let today = Calendar.current.startOfDay(for: now)
        var recordings = [Recording(title: "Le prochain chapitre", kind: .meeting, startedAt: today.addingTimeInterval(36_000), duration: 1934, state: .demo,
            notes: "Simplifier le premier lancement.\n\nUne session doit pouvoir commencer sans calendrier. Prévoir une correction des voix directement depuis le transcript.",
            noteEntries: [.init(offset: 190, text: "Garder le démarrage en un clic."), .init(offset: 765, text: "Revoir le parcours de correction des voix.")],
            speakers: [me, camille, unknown], segments: [
                .init(start: 12, end: 19, speakerID: me.id, source: .mic, text: "Je veux pouvoir enregistrer une idée sans créer une réunion. Le calendrier doit rester un contexte, pas un passage obligé."),
                .init(start: 21, end: 34, speakerID: camille.id, source: .system, text: "Alors on commence par un bouton, et on ajoute le contexte ensuite. Je peux préparer deux parcours de premier lancement pour comparer."),
                .init(start: 38, end: 46, speakerID: unknown.id, source: .system, text: "Et les notes prises pendant la discussion doivent rester au même endroit. C’est souvent là qu’on retrouve la décision, pas dans le résumé."),
                .init(start: 49, end: 62, speakerID: me.id, source: .mic, text: "Oui. On garde les notes, le transcript et l’audio ensemble, avec une correction simple quand une voix n’est pas reconnue."),
                .init(start: 66, end: 78, speakerID: camille.id, source: .system, text: "On teste avec une vraie conversation en salle avant d’aller plus loin. Les voix éloignées sont le cas le plus difficile.")
            ], summary: "Une première version centrée sur l’essentiel : commencer une session, prendre quelques notes et retrouver qui a dit quoi.\n\n## Décision\nLe calendrier enrichit la session. Il ne doit jamais être un préalable à l’enregistrement.\n\n## À suivre\n- Camille prépare deux parcours de premier lancement.\n- Tester la correction d’une voix sur une réunion en salle.", isDemo: true),
            Recording(title: "Une idée en marchant", kind: .voiceMemo, startedAt: today.addingTimeInterval(31_320), duration: 248, state: .demo, notes: "Et si le meilleur résumé était simplement la phrase qu’on a notée soi-même ?", speakers: [me], segments: [.init(start: 2, end: 12, speakerID: me.id, source: .mic, text: "Je pense à une interface qui s’efface pendant qu’on parle. Un bouton pour démarrer, et une page pour ce qui compte.")], isDemo: true),
            Recording(title: "Café avec Léa", kind: .conversation, startedAt: today.addingTimeInterval(29_700), duration: 1102, state: .demo, notes: "Reprendre la discussion sur l’atelier de jeudi.", isDemo: true),
            Recording(title: "Retour sur le prototype", kind: .call, startedAt: today.addingTimeInterval(-27_000), duration: 1462, state: .demo, notes: "Donner plus de place au transcript, sans masquer les notes.", isDemo: true)
        ]
        let ids = recordings[0].segments.map(\.id)
        var summary = SummaryContent(overview: "L’équipe définit un premier lancement simple et une relecture qui rassemble audio, transcript et notes.", decisions: [.init(text: "Permettre de démarrer sans événement calendrier.", evidence_segment_ids: [ids[0], ids[1]])], action_items: [.init(text: "Camille : Préparer deux parcours de premier lancement.", assignee_person_id: nil, due_date: nil, evidence_segment_ids: [ids[1]])])
        summary.key_points = [.init(title: "Démarrage immédiat", text: "Un bouton suffit, le contexte peut être ajouté ensuite.", evidence_segment_ids: [ids[0], ids[1]])]
        summary.details = [
            .init(title: "Un calendrier facultatif", text: "Une idée doit pouvoir être enregistrée sans créer de réunion. Camille propose un démarrage par un seul bouton et l’ajout du contexte ensuite. Deux parcours permettront de comparer le premier lancement.", evidence_segment_ids: [ids[0], ids[1]]),
            .init(title: "Retrouver le contexte et corriger les voix", text: "Les notes prises pendant la discussion restent avec l’audio et le transcript. Une correction simple doit permettre de rectifier une voix mal reconnue. Un test en salle est proposé, car les voix éloignées sont plus difficiles à distinguer.", evidence_segment_ids: [ids[2], ids[3], ids[4]])
        ]
        recordings[0].summary = summary.markdown
        recordings[0].summaryProvenance = SummaryProvenance(provider: "fixture", model: "fixture", promptVersion: "summary-v4", promptHash: "fixture", generatedAt: now, transcriptVersion: 1, inputHash: "fixture", structured: summary)
        return recordings
    }
}
