# Voice memory

Use **Nommer et mémoriser** in a speaker's name editor to create a local voice fingerprint from that cluster. **Nommer seulement** edits the transcript without enrollment. The voice panel also supports adding examples to an existing person and forgetting a person.

| Step | Behavior |
| --- | --- |
| Enrollment | At least 20 seconds, at most 60 seconds of non-overlapping speech from the selected cluster |
| Microphone audio | Reuses offline echo cancellation before extracting the voice sample |
| Embedding | FluidAudio 0.17.7, WeSpeaker 256 dimensions; one speaker is specified only for the already selected enrollment cluster |
| Channels | `near`, `room`, `remote`; remote audio is never compared against microphone exemplars |
| Matching | Runs automatically after diarization when voice memory exists; threshold and runner-up margin plus one-to-one assignment |
| Result | Name suggestions appear on transcript rows with **à confirmer**; manual names stay separate from enrollment |
| Failure | A locked keychain leaves a usable transcript and a visible warning |
| Storage | Vectors only in the local keychain. SQLite holds person metadata and enrolled channel names |

The personal-use UI records an explicit enrollment request in `enrollmentRequestedAt`. It does not manufacture a legal consent attestation in `consentedAt`. Existing consent metadata remains readable; opposition still disables recognition. This replaces the earlier multi-checkbox enrollment form. It does not claim legal compliance for deployment to other users.

A synthetic TTS fixture validates actual model extraction, keychain enrollment, same-voice matching and channel metadata. This is a technical regression check, not a real-world speaker-identification accuracy benchmark. The synthetic keychain entry is removed after the test.
