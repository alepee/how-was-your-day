# How Was Your Day

A native macOS app for recording, transcribing and reviewing conversations locally. Built with SwiftUI and Swift Package Manager.

**Experimental, Apple Silicon, macOS 26 or later.** The interface is currently in French.

## Install

```sh
brew install --cask alepee/tap/how-was-your-day
```

Or download the DMG from [GitHub Releases](https://github.com/alepee/how-was-your-day/releases).

The app uses a persistent local signing certificate, but is **not notarized by Apple**. On first launch, macOS may require **System Settings > Privacy & Security > Open Anyway**. Allow microphone and system audio access when you start recording. Calendar access is optional.

```sh
brew upgrade --cask how-was-your-day
```

## Features

- Record microphone and system audio as synchronized, separate tracks.
- Local French transcription with Apple SpeechAnalyzer; optional offline speaker diarization with FluidAudio.
- Review waveforms, play both tracks, solo or mute each track, and correct speaker assignments.
- Keep editable notes alongside the transcript and audio.
- Optional local summaries through an OpenAI-compatible server such as LM Studio. Reports include an overview, decisions, next steps and topic details with source references.
- Calendar context and explicit meeting reminders through macOS accounts, including Google and Microsoft accounts configured in Calendar.
- Light, dark and system appearance, menu bar access and a floating notepad.
- Versioned Markdown/JSON exports and a standalone stdio MCP server.
- Optional voice enrollment with explicit consent. Voice vectors stay in the macOS keychain, never in exports.

## Current limitations

Capture and speaker identity are experimental. Automatic echo rejection is not connected, so speakerphone audio may appear on both tracks. Changing audio devices stops the recording. Transcription runs after capture, with a fixed French locale; code-switching quality is not established.

Summaries require a separately running local server. Embedded MLX inference and remote API providers are not implemented. Structured output and source references do not guarantee accuracy: small models can omit decisions or distort details. Longer sessions use windowed generation and reduction, which also needs broader evaluation.

There is no automatic audio purge, app-level encryption, Sparkle updater or login item yet. Retention settings are not enforced. Uninstalling does not delete recordings or keychain entries. Voice matching thresholds are not calibrated on a representative corpus.

## Data and consent

Data lives in `~/Library/Application Support/HWYD`. Recording starts only on an explicit action. Inform participants and obtain the consent required for your use case. Renaming a speaker does not enroll their voice. Agents consuming your exports or MCP data may send that data elsewhere according to their own configuration.

First-run model downloads are explicit. Audio is processed locally. No real recordings or transcripts are included in this repository.

## Build

Install Xcode with Swift 6.2 or later and the macOS 26 SDK or later. No `.xcodeproj` is needed.

```sh
SIGN_IDENTITY='Your persistent code signing identity' scripts/build-app.sh debug
open 'build/How Was Your Day.app'
```

The developer default is the existing `No Bleeding Eyes Code Signing` identity. The build fails if that certificate is unavailable. For isolated development or CI only:

```sh
SIGN_IDENTITY=- HWYD_ALLOW_ADHOC=1 scripts/build-app.sh debug
```

Ad hoc signatures can cause repeated macOS permission prompts. Public release packaging refuses them. Never rebuild over an app that is recording. Use a separate output directory:

```sh
HWYD_APP_OUTPUT='build/validation/How Was Your Day.app' scripts/build-app.sh debug
```

## Test

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/HWYDCore
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
scripts/test-realtime.sh
python3 scripts/test-summary.py
'build/How Was Your Day.app/Contents/MacOS/HWYD' --self-test build/audio-test
'build/How Was Your Day.app/Contents/MacOS/HWYD' --ui-test build/ui-test
python3 scripts/test-mcp.py 'build/How Was Your Day.app/Contents/Helpers/hwyd-mcp' build/ui-test
'build/How Was Your Day.app/Contents/MacOS/HWYD' --snapshot build/screenshots
```

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

The [architecture draft](docs/architecture.md) describes the target, not a list of delivered features. See [release instructions](docs/distribution.md) for signing, packaging and Homebrew updates.
