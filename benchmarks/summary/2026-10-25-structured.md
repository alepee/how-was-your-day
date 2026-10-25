# Compte rendu structuré commun

Format demandé : notes Google Meet, avec résumé, points clés, décisions, étapes suivantes et détails par thème. Application à tous les types de session, sans sélecteur de template pour le moment.

Validation locale avec `google/gemma-4-e4b` via LM Studio. Deux cas synthétiques : engagement simple et trois sujets (plugins, calendrier, micro en salle). Aucun micro utilisé. Le cas à trois sujets couvre les trois thèmes et attribue correctement la tâche à Camille. La question du microphone reste ouverte. La génération narrative seule omettait les décisions dans leur rubrique ; une seconde passe dédiée aux engagements améliore l'extraction.

Limite observée sur le cas à trois sujets : une décision sur deux est remontée dans la rubrique Décisions. La seconde est présente dans les détails. Certaines reformulations restent maladroites. Ce test valide la structure, les références et la présence d'engagements, pas une exhaustivité sémantique complète ni une qualité équivalente à Gemini. Le test d'une longue session utilise un provider simulé pour vérifier la réduction, pas un benchmark de fidélité sur une heure réelle.

Compatibilité vérifiée avec les anciennes synthèses, refus d'un nom de responsable inconnu, références invalides et fusion de trois fenêtres. Snapshots clair et sombre inspectés. Le Markdown et le JSON exportent la même synthèse que l'app.
