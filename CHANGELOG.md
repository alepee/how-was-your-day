# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries describe what a user observes. The detailed release notes published on GitHub live in [`docs/releases/`](docs/releases/).

## [Unreleased]

### Added
- « Scinder la voix à partir d’ici… » in a transcript passage's menu, for one voice that was in fact two people speaking one after the other. It shows how many passages fall on each side of the cut with a way to listen to them, lets you choose which part keeps the current name, turns the other into a new voice and opens its name editor. « Nouvelle voix… » gives a single passage a voice of its own. Both can be undone from their notification and never touch a voice fingerprint.

### Changed
- Three session kinds instead of five: « Mémo » (`voice-memo`, alone), « Échange » (`exchange`, with others) and « Réunion » (`meeting`). Calls, conversations and free sessions recorded before become exchanges, in the app, its filter, `hwyd-mcp` and the next export of each session; files already exported keep their old value until then. A new session is an exchange by default, titled « Échange du … ».
- Declaring the people present informed and agreeing no longer takes a switch before a disabled « Démarrer »: for an exchange or a meeting, the start button works in two steps. It first reads « Consentement recueilli » and lands the dated stamp, then becomes « Démarrer l’enregistrement ». The declaration and its time are recorded as before. The menu bar follows the same two steps, without the stamp.
- Recording a calendar meeting preselects « Réunion » instead of imposing it: the kind can be changed while recording, like any other session.

## [0.16.0] - 2026-11-16

### Added
- Settings › General › « Langue de HWYD » (system language, Français, English) sets the interface, summaries and their exports, labels given to new voices and the examples. It applies at the next launch; Settings offer to relaunch. English summaries use English prompts at every stage and record their language; summaries already written keep theirs. Session exports, the MCP protocol and validation reasons sent to models are not translated. English summary quality is not benchmarked yet.
- Before recording a session with other people (any kind but a voice memo), the new session screen asks you to declare them informed and agreeing; « Démarrer » stays disabled until you do, and a dated stamp marks the declaration. The menu bar applies the same rule. The session and its JSON export record the declaration and its time (`consent_announced_at`). HWYD records your declaration, it does not collect consent from the participants, and the declaration is not consent to voice enrollment. The global shortcut and meeting reminders still start directly.

### Changed
- The new session screen is a centred card: name as title, kind as chips, microphone and language as menus, and its own actions.

## [0.15.0] - 2026-11-15

### Added
- Choose the microphone a session records, on the setup screen and while recording. HWYD remembers your last choice and uses the Mac's default input when that microphone is not connected. When macOS switches its default input during a recording (AirPods connecting, for example), HWYD asks first, with a notification offering « Basculer » or « Garder … » and the same question in the capture screen; not answering keeps the current microphone. For a Bluetooth headset, it warns that its microphone switches it to call mode. The permission to show notifications is asked the first time there is one to show, and no banner repeats a question already shown in the capture screen. If the microphone in use is unplugged, recording continues on the default input and HWYD tells you; with no microphone left, the session stops as interrupted and can be resumed. Exports and `hwyd-mcp` give the session's first microphone and each change. Switching has been checked with simulated devices; its behaviour with AirPods, Bluetooth headsets and USB interfaces is still to be confirmed on real hardware.
- « Reprendre l’enregistrement », in a session's header and its right-click menu, records the rest of a session you stopped or that was interrupted, up to 24 hours after it ended. The new audio follows the earlier audio, notes taken now follow the earlier ones, and the transcript marks « Reprise à … » where recording resumed. When recording stops, the whole session is transcribed again: corrections to its transcript are lost (you are asked to confirm first), and an existing summary is kept and marked as made from an earlier transcript. JSON exports and `hwyd-mcp` give where and when recording resumed.
- Exporting a summary (PDF or Markdown) first asks which sections to include, among those the summary has. « Résumé » is always included. « Contexte » starts unticked on every export, since its notes come from a coding agent's own sources and can be private; when ticked, its sources are exported with it. The PDF counts only the exported sections. Nothing is remembered between exports.
- Right-clicking a session, in the library or among the recent sessions of the sidebar, opens it, generates or regenerates its summary without opening it (or cancels a summary running or waiting), and deletes it. Deleting is unavailable while work runs or waits on the session.

### Changed
- Changing the audio output device during a recording no longer stops the session.

## [0.14.0] - 2026-11-14

### Added
- « Générer automatiquement » in Settings › Summary (off by default) starts a session's summary on its own, 10 seconds after the session is ready: transcript complete and every voice named, confirmed or ignored. A message announces each automatic summary and lets you cancel it. It makes one attempt per transcript version until the session has a summary, waits for other processing to end, and never processes sessions that ended before you turned it on. Turning it off drops the automatic summaries still waiting. When the summary cannot run (provider not configured), nothing is sent and the line under the Generate button says why. Known limits: a refused attempt is not retried until the transcript changes, and a session that was ready when you quit HWYD during its 10 seconds is not picked up at the next launch.
- The summary tab says when some voices are not identified yet, since the summary then refers to them generically.

### Changed
- The window no longer freezes for about a second when a meeting app takes the microphone during a capture: the capture now runs off the interface.
- Correcting voices or the transcript, or transcribing again, no longer deletes the summary. The summary tab says the transcript has changed since the summary; Regenerate refreshes it. Exports and MCP keep the summary and mark it stale, and its source references may point to passages that no longer exist.
- When a capture ends while other processing runs (a summary, a voice job, a model install), its transcription now waits its turn and starts on its own, instead of having to be started by hand. The transcript says it is waiting and can be cancelled.
- A processing request that cannot start now (another one runs, the session has no audio, the examples are open) says why in a message instead of doing nothing.
- A session being processed, voice recognition included, cannot be deleted until the processing ends or is cancelled; a message says so.
- When a summary cannot be generated (no API key, no model, no local server address, no agent command), a line under the Generate button says why.
- Notes or voice names written by an MCP client now show in the open app within a few seconds, even while you are editing or a processing runs, and are published to the export folder as soon as the app sees them.

### Fixed
- The summary tab no longer calls every draft local: with a hosted provider it names the provider the transcript is sent to, with an ACP agent it says the draft comes from the agent.
- English messages about a missing API key or model no longer read "a Anthropic" or "a OpenAI".
- When the local data cannot be opened at launch, the app now says so in a message instead of staying silent.
- Settings › Audio and voice now shows the voice separation models as installed only when they are on disk, instead of guessing from earlier sessions.
- Lifting an exclusion shows one message instead of two.
- An edit made in the app while an MCP client changed the same session is no longer stuck as unsaved: both changes are kept, and when both touched the same part (the notes, for instance) the app keeps yours and says so.
- A session an MCP client deletes while the app holds unsaved edits on it is no longer created again by the app: the edits are dropped and a message says so.

### Security
- **Deleting a session now deletes its audio.** Its audio files (both tracks), summary checkpoints, waveform cache and leftover job files are removed from the data folder, not only its notes and transcript. A file that cannot be removed is reported and retried on next launch. The first launch also removes the files left by sessions deleted with an earlier version. A session that is recording, transcribing or summarizing cannot be deleted. Voice fingerprints are unchanged: they belong to a person and are forgotten from the voice settings.

## [0.13.0] - 2026-11-13

### Added
- **In-app updates** with Sparkle: **Check for Updates…** in the app menu and the menu bar, and an Updates section in Settings › General. Automatic checks stay off until you accept the prompt shown on the second launch, no system profile is sent, and scheduled checks and relaunches wait until a capture or processing ends ([#21](https://github.com/alepee/how-was-your-day/pull/21)).
- **Summary export.** The summary tab has an export menu: PDF (A4, following the summary layout, every topic expanded) or Markdown (title, date and confirmed participants before the summary). Context notes from a coding agent stay out of both exports, since they can hold private information unrelated to the session.

### Changed
- Session tabs are ordered Summary, Transcript, Notes. A session opens on its summary when one exists, otherwise on its transcript.

### Fixed
- The microphone level no longer drops by about 30 dB when a meeting app opens the microphone after the capture started and switches on voice processing. The capture watches the processes reading audio input and restarts its stream once a newcomer has settled.

## [0.12.1] - 2026-11-13

### Fixed
- Recording now starts with audio interfaces that also have outputs (for example the Native Instruments Komplete Audio 6). macOS can leave a gap in channel numbers between the microphone and system audio; the check now only requires the microphone to come first. Channel counts, sample format and sample rate are still verified before recording starts.

## [0.12.0] - 2026-11-13

### Added
- Context notes written by a coding agent are shown in their own collapsible **Context** section, with their sources and a help button explaining that they do not come from the conversation.
- On wide windows (942 pt and more), an outline next to the summary lists sections and topics, highlights the one on screen and jumps to it.

### Changed
- **The summary tab is laid out for reading**: a column of bounded width, the overview first, then counters for decisions, next steps, topics and context notes that jump to their section. Key points appear as cards, decisions get an accent bar, and each next step is one row with its owner, action and due date.
- Source references are one compact button per item (`▸ 29:13 +2`): hovering lists every passage, clicking moves playback to the first one.
- Topics in Details can be collapsed; with more than three topics they start collapsed and **Expand all** opens them.

## [0.11.0] - 2026-11-10

### Added
- The interface is available in French and English, following the macOS language order or the per-app language.
- Transcription detects the language of each track (microphone and system) from its first 90 seconds, among the Apple Speech languages installed for HWYD. The setup screen can force one language, and a transcribed session can be transcribed again in another language.
- A notification offers to install a missing language and transcribe again. Settings › Audio & Voice lists and installs languages.
- Global shortcut to start or end a recording (default ⌃⌥⌘R), configurable in Settings › General.
- Exports add `track_locales`. `hwyd-pipeline languages` prints the installed and supported speech locales as JSON.

### Changed
- Releases are signed with a Developer ID certificate and notarized by Apple. macOS treats the app as new once: permissions and keychain access may be asked again.

### Removed
- The default transcription language setting.

### Fixed
- Retrying a failed transcription keeps the requested language.
- Chinese and Cantonese are recognized by language detection.

## [0.10.0] - 2026-11-10

### Added
- Recording works with a Bluetooth headset microphone: microphone and system audio run on separate device clocks, aligned on host time with drift compensation beyond 2 ms.

### Changed
- When buffers are lost, the error gives the cause counters.

## [0.9.1] - 2026-11-10

### Changed
- When a recording cannot start because of the audio layout, the message names the check that failed and the values read (channel count, stream order, sample format, sample rates).

## [0.9.0] - 2026-11-10

### Added
- **Nouvelle session** opens a setup screen; nothing is captured before recording starts.
- Stacked notifications in the corner of the window, with buttons when a decision is needed.
- Voice corrections can be undone from their notification, and a merged voice can be split back with **Séparer**.
- Each voice sample remembers its session. A person's samples can be withdrawn per session, the print erased, or the person excluded and later restored.

### Changed
- Voice enrollment happens on the voice tiles; the « Identité des voix » panel is gone.
- Voice prints have two channels, microphone and call, deduced from the track. Former « Proche » and « Salle » samples are merged into the microphone channel. Cross-channel suggestions use a stricter threshold (0.85).

## [0.8.0] - 2026-11-10

### Added
- **Agent (ACP)** summary provider: a local coding agent (Claude Code, Codex, Mistral Vibe, Grok, Gemini CLI or any ACP command) writes the summary, with a separate **Contexte** section for what it brings from its own context. The agent submits through a session-scoped `submit_summary` MCP tool; HWYD refuses edits, deletions and commands.
- Hosted providers list the provider's models after a key is saved; a rejected key is not stored.
- Meeting reminders offer « Rejoindre et enregistrer » and « Enregistrer ».

### Changed
- Choosing a hosted provider and saving its key is the opt-in; the separate "send transcripts" switch is gone.
- Hosted providers retry a stage once on invalid output, and errors name the failed rule.

## [0.7.0] - 2026-11-10

### Added
- Hosted summary providers: Mistral, OpenAI, Anthropic and Google Gemini, with your own API key stored in the macOS keychain. Hosted models read up to 200,000 characters per request.

### Changed
- Provider errors show the provider's own message.

## [0.6.0] - 2026-11-09

### Changed
- Quieter Studio interface: one name and icon for starting a session, a player half as tall, voice tiles on every tab, a single menu button per transcript line, explanations moved to tooltips and help buttons, four text sizes.
- Settings apply immediately, one per line, and show whether models are installed. « Données locales » and « Agents et exports » are merged.
- The example voice "Speaker 3" is renamed "Voix 3".

### Removed
- The audio retention preference, which never deleted anything (the stored value is kept).

## [0.5.0] - 2026-11-06

### Added
- Voice tiles: play one voice's passages, name it once for the recording, drag one voice onto another to merge them.
- Ignore a voice (typically a speaker echo): its passages are hidden from the transcript, exports, MCP and summaries, and can be restored.
- The active transcript line follows playback.
- Pause and resume a recording (⌘⇧P).
- `hwyd://session/<id>` links, exposed by MCP as `source`.

### Changed
- Releases are signed with an `Apple Development` identity instead of a self-signed certificate.

### Fixed
- Exports and MCP no longer promise a summary that was not generated.

## [0.4.0] - 2026-10-26

### Added
- Option to disable extended reasoning on compatible local servers.

### Changed
- Local summaries use bounded requests: short transcripts take two calls, longer ones are organized by topic and written from their original passages, with commitment checks before drafting.
- Audio model jobs and summary generation no longer run concurrently. Checkpoints stay resumable, and oversized inputs are rejected instead of truncated.

### Fixed
- A summary verification step is validated before being cached, and retried once when invalid.
- Pending edits are saved before the summary snapshot, cancellation is handled cleanly, and progress no longer shows a premature 100%.

## [0.3.0] - 2026-10-26

### Added
- Conservative "possible echo" markers on microphone fragments that match nearby system speech.
- MCP structured reads filter by time, track, speaker and attribution/echo.
- Summary stage progress and a context setting matching the loaded local model.

### Changed
- Stronger offline residual echo suppression before transcription.
- MCP transcript pages keep segment boundaries and default to 30,000 characters.
- Summaries map topics before writing from the original transcript, with local checkpoints.

## [0.2.1] - 2026-10-26

### Fixed
- Each confirmed person is listed once in session labels, MCP metadata and exports when several voice clusters link to them.

## [0.2.0] - 2026-10-26

### Added
- Voice memory: **Nommer et mémoriser** saves a local voice print; new diarized transcripts suggest remembered voices to confirm. Voice prints stay in the macOS keychain.

## [0.1.1] - 2026-10-26

### Added
- Offline echo cancellation before transcription and diarization; original audio is kept.
- Product page on GitHub Pages.

### Fixed
- Responsiveness on long transcripts (lazy rows, local speaker-name editing, cached waveforms).
- Calendar reminders stay active after opening or recording an event.

## [0.1.0] - 2026-10-25

### Added
- First experimental release for Apple Silicon and macOS 26+: separate microphone and system audio recording, local French transcription, optional diarization, notes and speaker corrections, optional local summaries, calendar reminders, Markdown/JSON exports and a standalone MCP server.

[Unreleased]: https://github.com/alepee/how-was-your-day/compare/v0.16.0...HEAD
[0.16.0]: https://github.com/alepee/how-was-your-day/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/alepee/how-was-your-day/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/alepee/how-was-your-day/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/alepee/how-was-your-day/compare/v0.12.1...v0.13.0
[0.12.1]: https://github.com/alepee/how-was-your-day/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/alepee/how-was-your-day/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/alepee/how-was-your-day/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/alepee/how-was-your-day/compare/v0.9.1...v0.10.0
[0.9.1]: https://github.com/alepee/how-was-your-day/compare/v0.9.0...v0.9.1
[0.9.0]: https://github.com/alepee/how-was-your-day/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/alepee/how-was-your-day/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/alepee/how-was-your-day/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/alepee/how-was-your-day/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/alepee/how-was-your-day/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/alepee/how-was-your-day/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/alepee/how-was-your-day/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/alepee/how-was-your-day/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/alepee/how-was-your-day/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/alepee/how-was-your-day/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alepee/how-was-your-day/releases/tag/v0.1.0
