# Diagnostic de capture du 23 octobre 2026

Symptôme : compteur actif, niveaux nuls et dossiers audio vides, avec une interface Komplete Audio 6 sélectionnée comme entrée macOS.

Cause identifiée : `kAudioAggregateDeviceTapAutoStartKey` était activé. D’après le header Apple `AudioHardware.h`, ce réglage retarde le démarrage de l’aggregate jusqu’à l’arrivée d’audio dans une application capturée. Il ne convient pas aux conversations en salle sans audio système.

Correction : désactiver cette attente. Attendre un premier buffer traité avant de déclarer la capture démarrée. Abandonner après cinq secondes sans buffer. Arrêter avec une erreur si les buffers cessent pendant trois secondes. Un arrêt sans tranche audio ne doit pas annoncer une transcription à venir.

Validation : compilation et test synthétique réussis. Antoine a confirmé le fonctionnement du micro après acceptation de la nouvelle demande macOS. Deux CAF ont été produits lors de cet essai. Cela ne valide pas encore les appels Meet/Gather/Huddle, la dérive matérielle ou les changements de périphérique. La signature ad hoc peut déclencher une nouvelle demande TCC après reconstruction.

Référence : SDK macOS installé, `CoreAudio.framework/Headers/AudioHardware.h`, documentation de `kAudioAggregateDeviceTapAutoStartKey` ; [symbole Apple](https://developer.apple.com/documentation/coreaudio/kaudioaggregatedevicetapautostartkey).

## Call apps and the microphone (2026-11-28, macOS 27.0.1)

Symptom: during a FaceTime or Google Meet call, the microphone track stayed about 25 to 35 dB too quiet. A pause and resume did not help on the built-in microphone, and joining or leaving a call stopped the recording with « La capture a perdu des buffers audio (3/0/0/0) » or « (0/0/2/0) ».

Observations, without HWYD, with a meter reading the device directly:

- **Built-in microphone (MacBook Pro).** As soon as a call app uses voice processing (FaceTime through `avconferenced`, Meet in Chrome, Zen or Safari), the device goes from 1 to 3 input channels at 48 kHz (also visible in Audio MIDI Setup), and every other reader, System Settings included, gets the voice about 35 dB lower on all three channels. None of them carries the processed signal. It goes back to 1 channel a few seconds after the call ends. Raised by about 38 dB, the capsules carry an intelligible voice; a cross-correlation with the call audio showed it was the voice in the room, ahead of the call path by about 450 ms, not the speakers.
- **Komplete Audio 6.** The format does not change (6 channels, 48 kHz, no software input volume), but a stream already running when the call starts drops about 25 dB on its microphone channel until it restarts. HWYD, which restarts on a new reader (`MicrophoneClaimWatch`), kept its level while the meter's never-restarted stream stayed low.

Correction: the capture follows the microphone's format. A change of channel count builds the graph again instead of failing, and the built-in microphone's capsules are averaged and raised (`MicrophoneReading`). The claim restart stays for external microphones. See [architecture](architecture.md), « Call apps and the microphone ».

Validation: `--self-test` simulates a call taking and releasing the built-in microphone. Manually, with the built-in microphone, a recording that started before a FaceTime call kept going through joining and leaving, at about -31 dB RMS before, -33 during and -30 after, and its transcript covered the whole session. A recording resumed during a call was at -29 dBFS (90th percentile) instead of -68. Only one MacBook Pro was measured; the gain may differ on other Macs.

Also seen: after several tests in a row, the built-in microphone once stayed silent for every app after the call ended, until `coreaudiod` was restarted (`sudo killall coreaudiod`). It did not happen again and was not tied to HWYD.
