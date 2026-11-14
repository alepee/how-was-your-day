# How Was Your Day

[Website](https://alepee.github.io/how-was-your-day/) · [Download](https://github.com/alepee/how-was-your-day/releases/latest) · [Changelog](CHANGELOG.md)

A native macOS app for recording, transcribing and reviewing conversations locally. Built with SwiftUI and Swift Package Manager.

**Experimental, Apple Silicon, macOS 26 or later.** The interface follows the macOS language: English, or French otherwise. Demo content, stored default voice labels ("Voix 1", "Voix à nommer") and summaries stay in French.

## Install

```sh
brew install --cask alepee/tap/how-was-your-day
```

Or download the DMG from [GitHub Releases](https://github.com/alepee/how-was-your-day/releases).

From 0.11.0, the app is signed with a Developer ID certificate and notarized by Apple. Allow microphone and system audio access when you start recording. Calendar access is optional.

```sh
brew upgrade --cask how-was-your-day
```

## Features

- Record microphone and system audio as synchronized, separate tracks.
- Pause and resume a recording without ending the session (button or ⌘⇧P). During a pause the audio device is stopped, so neither the microphone nor system audio is captured; the paused time is left out of the recording timeline, so notes stay aligned with the audio.
- Local transcription with Apple SpeechAnalyzer (SpeechTranscriber), in any language it supports that is installed for HWYD (about 350 MB per language, downloaded once, managed in Settings > Audio & Voice). The language is detected per track (microphone and system) from the start of each track; a session can also be set to one language on the setup screen and reprocessed in another. When a track seems to be in a language that is not installed, HWYD offers to install it and transcribe again. Optional offline speaker diarization with FluidAudio.
- Review waveforms, play both tracks, solo or mute each track, and correct speaker assignments.
- Keep editable notes alongside the transcript and audio.
- Optional summaries: local through an OpenAI-compatible server such as LM Studio, hosted through the Mistral, OpenAI, Anthropic or Google Gemini APIs with your own API key, or written by your own coding agent over the Agent Client Protocol (Claude Code, Codex, Mistral Vibe, Grok, Gemini CLI), which can use what it knows about you in a separate context section. Reports include an overview, key points, decisions, next steps and collapsible topic details; each item links to its source passages in the recording.
- Calendar context and explicit meeting reminders through macOS accounts, including Google and Microsoft accounts configured in Calendar.
- Light, dark and system appearance, menu bar access and a floating notepad.
- A global shortcut starts or ends a recording from any application, without bringing the window forward (default ⌃⌥⌘R, configurable or removable in Settings > General). It needs no Accessibility permission.
- Versioned Markdown/JSON exports and a standalone stdio MCP server with segment-aware pagination, structured transcripts and time/speaker/track filters.
- Voice tiles in the session view: one per detected voice with its state (unidentified, proposed, confirmed). A click plays only that voice's passages back to back. Naming, confirming, linking to a known person or regrouping duplicates (menu or drag and drop) applies to the whole session and never creates a voice fingerprint. Two unnamed voices on different tracks must be named before they can be regrouped. A voice can also be ignored (speaker echo, noise): its passages are hidden from the transcript, the Markdown export, search, MCP and summaries, and can be restored from the tile.
- The transcript follows playback and highlights the passages being heard. Scrolling pauses the follow; « Suivre la lecture » resumes it.
- Explicit local voice enrollment from a voice tile, with automatic name suggestions after diarization. The channel (microphone or call) follows the track; a person known on only one channel can be suggested on the other above a stricter threshold. Settings show what each session added to a voice print and can withdraw it, erase the print, or oppose recognition. Voice vectors stay in the macOS keychain, never in exports.
- Voice corrections can be undone from their notification, and a regrouped voice can be split back later.

## Current limitations

Capture and speaker identity are experimental. HWYD applies experimental offline acoustic echo cancellation to a temporary microphone copy for dual-track transcriptions before speech recognition and diarization. Original playback audio is unchanged. Residual echo and simultaneous speech still require review. Existing transcripts need reprocessing. Changing audio devices stops the recording. With a Bluetooth headset in call mode, the microphone and system audio run on two clocks that HWYD aligns itself; long-session drift has only been measured on synthetic audio. Transcription runs after capture. Language detection reads only the first 90 seconds of each track: a language change later in the session is not followed, and code-switching inside a track or a sentence is not handled. Portuguese may be suggested as Spanish (the message names both). Korean speech produces no text with French or English models and is treated like silence. Sessions recorded before 0.11.0 keep French unless reprocessed in another language.

Summaries require a separately running local server, a hosted provider API key, or an installed and signed-in ACP agent. An agent receives the session title, transcript and voice names, reads its own context, and returns the summary through the `submit_summary` tool of a restricted `hwyd-mcp`; HWYD refuses its requests to edit, delete or run commands, but permissions already granted in the agent's own configuration are its own. Embedded MLX inference is not implemented. With a hosted provider, the session title, transcript and voice names are sent to that provider on each summary, under its own data terms. Selecting a hosted provider and saving its key is the opt-in: the key is checked by listing the provider's models, which the settings then offer as a list and as completions. Notes, audio and voice fingerprints are never sent. API keys are stored in the macOS keychain. Hosted models read much larger portions per request, so a typical session needs only a few requests; costs are billed to your provider account. Hosted structured-output support varies by model: a model that rejects the schema reports the provider's error. The workflow extracts evidence from bounded portions, writes from the original words and checks proposed commitments. Short sessions avoid unnecessary topic routing. Requests run sequentially, with local checkpoints and stage progress. Audio model jobs and summary generation do not run concurrently inside HWYD. A summary can be exported on its own, as PDF or Markdown, from the summary tab: title, date, confirmed participants, then the summary. Context notes an agent draws from its own sources stay out of the export. Exports to Notion or Google Docs are not available.

Structured output and source references do not guarantee accuracy. Models can omit decisions or distort details, and summaries still need review. French, English and mixed transcripts have a synthetic [benchmark suite](docs/summary-benchmark.md); summaries are currently written in French. Input budgets limit each request, not the external server's memory allocation or model cache. With a local server, verify the context it actually reports. The optional reasoning toggle helps models that otherwise return no final JSON. See [summary workflow](docs/summary-workflow.md).

There is no automatic audio purge, app-level encryption or login item yet. Retention settings are not enforced. Deleting a session does not erase manual exports, copies made by agents, backups, or the freed pages of the SQLite file. Uninstalling does not delete recordings or keychain entries. Voice matching thresholds are not calibrated on a representative corpus.

## Data and consent

Data lives in `~/Library/Application Support/HWYD`. Deleting a session removes it from the library and the publication folder, then removes its files from this folder: audio of both tracks, summary checkpoints, waveform cache and leftover job files. A file that cannot be removed is reported and retried on next launch; each launch also removes the files of sessions deleted by an earlier version. Voice fingerprints belong to a person, not to a session, and are forgotten from the voice settings. Recording starts only on an explicit action. Inform participants and obtain the consent required for your use case. “Name only” and every other voice correction change the transcript; “Name and remember” and “Remember this voice” also add a local voice fingerprint, after an explicit action. Suggested names require confirmation. Agents consuming your exports or MCP data may send that data elsewhere according to their own configuration. A hosted summary provider receives the transcript only after you enable it.

First-run model downloads are explicit. Audio is processed locally.

Release builds include a Sparkle updater. On the second launch, Sparkle asks whether to check for updates automatically; until you accept, HWYD makes no update request. A check downloads the release list from GitHub and sends no system profile. Scheduled checks are skipped during a recording or a transcription, and a downloaded update never relaunches the app before they end. "Check for Updates…" is in the app menu, the menu bar and Settings › General. The first version with the updater must be installed manually or through Homebrew; development and CI builds never check. No real recordings or transcripts are included in this repository.

## Build

Install Xcode 27 with Swift 6.4 or later. The pinned Swift Collections dependency requires Swift 6.4; the app deployment target remains macOS 26. No `.xcodeproj` is needed. `make build` wraps the command below.

```sh
SIGN_IDENTITY='Your persistent code signing identity' scripts/build-app.sh debug
open 'build/How Was Your Day.app'
```

The local default is an `Apple Development` identity (a free Apple ID added in Xcode is enough). Its team ID keeps keychain and privacy permissions valid across rebuilds. The build fails if no matching certificate is available. For isolated development or CI only:

```sh
SIGN_IDENTITY=- HWYD_ALLOW_ADHOC=1 scripts/build-app.sh debug
```

Ad hoc signatures can cause repeated macOS permission prompts. An ad hoc signature has no team ID, so an ad hoc build disables library validation to load its embedded Sparkle. Public release packaging refuses them. Never rebuild over an app that is recording. Use a separate output directory:

```sh
HWYD_APP_OUTPUT='build/validation/How Was Your Day.app' scripts/build-app.sh debug
```

## Test

`make help` lists the shortcuts: `make check`, `make test` (no app needed), `make test-app` (synthetic checks against the built app), `make snapshot`, and `make ci` for everything CI runs. The underlying commands:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/HWYDCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
scripts/test-realtime.sh
python3 scripts/test-summary.py
'build/How Was Your Day.app/Contents/MacOS/HWYD' --self-test build/audio-test
'build/How Was Your Day.app/Contents/MacOS/HWYD' --ui-test build/ui-test
python3 scripts/test-mcp.py 'build/How Was Your Day.app/Contents/Helpers/hwyd-mcp' build/ui-test
'build/How Was Your Day.app/Contents/MacOS/HWYD' --snapshot build/screenshots
'build/How Was Your Day.app/Contents/MacOS/HWYD' --snapshot build/screenshots-en -AppleLanguages '(en)'
python3 scripts/l10n.py check
```

`scripts/l10n.py check` fails when a String Catalog entry lacks French or English, or when a French literal in `Sources/HWYDApp` is not localizable. See [localization](docs/localization.md).

Use fresh test directories. Demo, snapshot, self-test and UI-test modes never capture the microphone. Tests using installed speech or diarization models are separate, opt-in checks.

## MCP

Configure your MCP client with this executable, using an absolute path:

```json
{
  "mcpServers": {
    "hwyd": {
      "command": "/Applications/How Was Your Day.app/Contents/Helpers/hwyd-mcp"
    }
  }
}
```

The app does not need to be running. Reads are enabled by default. Writing notes or renaming speakers requires both the app preference and the `--allow-write` argument.

## Project

| Path | Purpose |
| --- | --- |
| `Sources/HWYDApp` | SwiftUI app, capture and playback |
| `Sources/HWYDRealtime` | Allocation-free C audio callback and SPSC buffer |
| `Sources/HWYDPipeline` | Isolated speech, diarization and identity helper |
| `Sources/HWYDMCP` | Standalone MCP server |
| `Packages/HWYDCore` | Models, store, summaries, exports and tests |
| `docs` | Original French design documents, including planned features |

The [architecture draft](docs/architecture.md) describes the target, not a list of delivered features. See [release instructions](docs/distribution.md) for signing, packaging and Homebrew updates, and [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution workflow.
