# Voice memory

Memorize a voice from its tile in a session. A named voice offers **Mémoriser cette voix…**, which asks for confirmation; an unnamed one opens the name editor, where **Nommer et mémoriser** names it and memorizes it. **Nommer seulement**, confirming a proposal, linking to a known person and regrouping voices edit the transcript only: they never read or write a voice print.

| Step | Behavior |
| --- | --- |
| Enrollment | At least 20 seconds, at most 60 seconds of non-overlapping speech from the selected voice |
| Microphone audio | Reuses offline echo cancellation before extracting the voice sample |
| Embedding | FluidAudio 0.17.7, WeSpeaker 256 dimensions; one speaker is specified only for the already selected enrollment cluster |
| Channels | `mic` and `remote`, deduced from the voice's track. A voice is compared with the person's exemplars on its own channel; when the person has none there, the other channel is tried with a stricter threshold (0.85 instead of 0.75) and the proposal is flagged `cross_channel` in exports |
| Matching | Runs automatically after diarization and after each enrollment; threshold and runner-up margin plus one-to-one assignment, so one person is proposed for at most one voice per session |
| Result | Name suggestions appear on the tiles and transcript rows with **à confirmer**; manual names stay separate from enrollment |
| Traceability | Each stored sample keeps the session and voice it came from, in the keychain only. Settings › Audio et voix lists, per person, what each session added and can withdraw it. Samples stored before 0.9 are grouped as unknown origin |
| Withdrawal | **Retirer** removes one session's samples. **Effacer l’empreinte** removes all samples and keeps the person. **Effacer et opposer** also blocks enrollment and recognition until **Lever l’exclusion**, after which a new enrollment is required |
| Failure | A locked keychain leaves a usable transcript and a visible warning |
| Storage | Vectors and their origin only in the local keychain. SQLite holds person metadata and enrolled channel names |

Voice memory requests are never refused because other work runs:

- **Mémoriser** and **Reconnaître les voix** wait their turn behind a transcription, a summary or a model install. The name is applied at once; the tiles show « En attente… » with **Annuler**. When its turn comes, the enrollment reads the voice again: if it no longer bears that name, or the person opposed meanwhile, nothing is memorized and a notice says so.
- **Retirer**, **Effacer l’empreinte**, **Effacer et opposer** and **Lever l’exclusion** run at once, even during a transcription. They only wait for an enrollment or a recognition that is running, and go before any that waits. Erasing or opposing cancels the person's enrollments still to come, running or waiting; withdrawing a session cancels its enrollment for that person. A transcription that read a print before it was erased or opposed does not propose that person.

Corrections can be undone: each voice correction shows **Annuler** in its notification, and a voice merged into another on the same track can be split back later with **Séparer** in the tile menu.

When diarization gives one voice to two people who spoke in turn, **Scinder la voix à partir d’ici…** in a passage's menu cuts the voice at that passage. The passages before it and those from it on become two voices on the same track: a named voice lets the user choose which part keeps its name, and the other part becomes a new voice whose name editor opens. **Nouvelle voix…** does the same for one passage. Like naming, splitting edits the transcript only and never reads or writes a voice print. A print already memorized from a voice that held two people is not corrected by the split: withdraw that session's samples in Settings › Audio et voix.

Before 0.9 the microphone was split into `near` and `room`. Those samples move to `mic` the first time they are read, keeping at most 20 per channel.

The personal-use UI records an explicit enrollment request in `enrollmentRequestedAt`. It does not manufacture a legal consent attestation in `consentedAt`. Existing consent metadata remains readable; opposition still disables recognition. It does not claim legal compliance for deployment to other users.

`scripts/test-voice-memory.sh` checks enrollment per channel, the cross-channel proposal, sample origins and the withdrawal of one session with two synthetic TTS voices, in a throwaway store. It is a technical regression check, not a real-world speaker-identification accuracy benchmark. Its keychain entries are removed after the test.
