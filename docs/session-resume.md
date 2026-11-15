# Resuming a session

Status: implemented.

Recording can continue in a session that has ended, whether the user stopped it or the capture was interrupted (device change, sleep, fault, crash). The new audio follows the earlier audio on the session's timeline, the transcript is made again from the whole session, and the place where recording resumed is marked.

## When a session can be resumed

"Resume recording" is offered on a session when all of these hold:

- it is not a demo session and holds no simulated capture;
- it is sealed or interrupted (not recording);
- it ended less than 24 hours ago (see `endedAt` below);
- no capture runs or starts;
- no summary or voice job runs or waits on it.

A transcription that runs or waits on the session is cancelled when recording resumes: the transcript is made again at the end anyway. While recording, the session accepts no summary or voice job.

The rule is `SessionResume.refusal` in HWYDCore. Examples, a session being recorded and a session past the window hide the action; another capture or work on the session shows it disabled, with the reason.

Past 24 hours the action is not shown. Sessions recorded before this feature have no `endedAt`; their end is taken as `startedAt + duration`, which can be earlier than the real end (pauses are not counted), so the window is never longer than 24 hours.

## What the user sees

- **Entry points**: a "Reprendre l'enregistrement" button in the session header, and the same entry in the session context menu.
- **Confirmation**, only when the session has a transcript: the transcript will be made again from the whole session once recording stops, so corrections made to it (text, named voices, merges, ignored voices) are lost. Voices kept in the voice memory are proposed again as usual. A summary is kept and marked out of date.
- **During capture**: the usual capture screen. The clock starts at the session's recorded duration, so notes taken now follow the earlier ones on the same timeline.
- **After stop**: as for any capture, the session is sealed or interrupted, then its transcription is requested and waits its turn.
- **Resume marker**: a line "Reprise à 14:32" (the time in the user's format) in the transcript, before the first segment at or after the resume point. No marker in the waveform for now.

Title, kind, calendar context and transcription language are unchanged.

## Model

`Recording` gains two fields, both optional so earlier sessions decode unchanged:

- `endedAt: Date?`: wall-clock time the last capture of the session stopped. Set by `CaptureSession.stop`. A session ended by a crash keeps the `endedAt` of its previous stop, if any.
- `boundaries: [CaptureBoundary]?`, with `CaptureBoundary { offset: Double; at: Date; reason: CaptureBoundaryReason; microphone: String? }`: where on the session's timeline (recorded seconds) the capture changed, the wall-clock time, why, and the name of the input device used from there on when the capture can tell (`AudioCapture.microphone`). `CaptureBoundaryReason` is `resumed`, `user`, `accepted` or `forced`. Only `resumed` is produced by this feature; the other three are produced by [switching the microphone](microphone-switch.md) during a recording, in the same list.

`SessionStore` keeps each session as an encoded JSON payload (`ui_recordings`), so no migration is needed. `RecordingMerge` merges both fields with the capture part, like `audioChunks` and `duration`.

## Capture

- `AudioCapture.start(session:continuing:)` takes a `CaptureContinuation`: the timeline offset of the first new chunk and the first file sequence number. `CaptureContinuation(after:)` takes the later of the session's `duration` and the end of its last chunk, on a 16 kHz frame: the clock and the audio can differ by a few milliseconds at a stop, and the pipeline refuses overlapping chunks. Chunks are written in mic/system pairs sharing one number, so there is one sequence for both tracks: one past the highest the session's chunks record, and `CoreAudioCapture` also skips any number already on disk in the session folder (a pair recovery skipped). `CoreAudioCapture` numbered files from `000000` at every start, which would have overwritten the earlier audio.
- `CaptureSession.continueRecording(_:with:in:)` (`resume()` already means un-pause) checks the session's own conditions, refuses a simulated capture, starts the capture at the continuation, flips the session to `recording`, appends a `resumed` boundary and starts the clock at the offset. `AppModel.resumeRecording` checks the work on the session in the order of the other requests and uses the same capture source as a new session (microphone permission, capture lock). It cancels the session's transcription only once the capture runs, so a capture that cannot start leaves the transcription waiting or running. The cancelled run ends silently and leaves the transcript state as it was; if the capture stops before that run ends, the transcription asked at the stop waits behind it (`WorkCoordinator` queues a job asked again while its cancelled run ends).
- `stop` appends the new chunks to `audioChunks` instead of replacing them, sets `duration` and `endedAt`, and requests the transcription whenever the session holds audio, even if this capture received none.
- Crash during a resumed capture: chunk descriptors (`NNNNNN.json`) record absolute start frames, so `AudioRecovery` places recovered chunks on the session timeline; `recoverInterrupted` keeps the chunks the session already held, with their ids, and adds the recovered ones (`AudioRecovery.merge`). This also covers earlier chunks written before descriptors existed.

## Transcription and summary

- The transcription runs on the whole session, as "transcribe again" does today: `applyTranscription` replaces segments and speakers. This is the agreed trade-off (option 1).
- The offline echo canceller starts again at each boundary: the request carries the boundary offsets (`echoResets`), and the helper processes each part between two boundaries with a fresh adaptive filter, since a resume can happen with another microphone or in another room. The timeline keeps its length.
- Diarization stays one pass over the whole session: a voice heard through another microphone or in another room may be split into a new voice, to merge by hand.
- The text sent for a summary carries the resume marker (a `resumed` field on the passage that follows it, for both the HTTP providers and the ACP agent), so the provider knows the session was cut. The summary input hash includes the boundaries; it is unchanged for sessions never resumed.
- An existing summary becomes stale through `transcriptVersion`, as for any new transcription. The automatic summary only runs on sessions without one; its "ended since the setting was turned on" uses `endedAt` when present.

## Exports and MCP

- JSON export: `ended_at` uses `endedAt` when present, and `capture_boundaries` (`offset_us`, `at`, `reason`, `microphone`) appears once the session has boundaries; a session never resumed exports byte for byte as before, so a revision published earlier is not reported as a conflict.
- Markdown export: the line `**[00:12:15] Reprise à 14:32**` (24-hour local time) before the first passage after each resume. The summary PDF and Markdown exports hold no transcript, so they carry no marker.
- `hwyd-mcp` `get_recording` and `list_recordings`: `capture_boundaries` in the recording metadata, always present (empty when the capture never changed), and the marker line in the Markdown transcript, for resumes inside the requested time range, before the first selected passage after each. Read-only, no new tool.
- Only `resumed` boundaries show a marker.

## Out of scope

- Transcribing only the new part and keeping corrections (option 2).
- A marker in the waveform or the player.
- Resuming more than 24 hours after the end, or resuming into a different session kind or language.

## Checks

- Resume a sealed session: earlier audio untouched, new chunks numbered after the old ones and placed at `duration`, notes aligned, one `CaptureResume` stored.
- Resume an interrupted session, then crash: recovery keeps both parts (unit test with a store, and `--self-test` with the real writer).
- Refused past 24 hours, during a summary or voice job, for a demo session, while another capture runs.
- A queued transcription of the session is cancelled when recording resumes, and requested again at stop.
- Transcript, Markdown, JSON and MCP show the resume marker; the summary input contains it.
- No microphone in synthetic checks: `SimulatedCapture` covers the flow.
