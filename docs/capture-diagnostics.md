# Diagnostic de capture du 23 octobre 2026

Symptôme : compteur actif, niveaux nuls et dossiers audio vides, avec une interface Komplete Audio 6 sélectionnée comme entrée macOS.

Cause identifiée : `kAudioAggregateDeviceTapAutoStartKey` était activé. D’après le header Apple `AudioHardware.h`, ce réglage retarde le démarrage de l’aggregate jusqu’à l’arrivée d’audio dans une application capturée. Il ne convient pas aux conversations en salle sans audio système.

Correction : désactiver cette attente. Attendre un premier buffer traité avant de déclarer la capture démarrée. Abandonner après cinq secondes sans buffer. Arrêter avec une erreur si les buffers cessent pendant trois secondes. Un arrêt sans tranche audio ne doit pas annoncer une transcription à venir.

Validation : compilation et test synthétique réussis. Antoine a confirmé le fonctionnement du micro après acceptation de la nouvelle demande macOS. Deux CAF ont été produits lors de cet essai. Cela ne valide pas encore les appels Meet/Gather/Huddle, la dérive matérielle ou les changements de périphérique. La signature ad hoc peut déclencher une nouvelle demande TCC après reconstruction.

Référence : SDK macOS installé, `CoreAudio.framework/Headers/AudioHardware.h`, documentation de `kAudioAggregateDeviceTapAutoStartKey` ; [symbole Apple](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedevicetapautostartkey).
