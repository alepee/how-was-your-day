# Switching the microphone during a recording

Status: implemented; the three hardware spikes below are still open and are checked by hand (see « Implementation notes »). Depends on [session resume](session-resume.md) for the capture boundary model.

The user chooses the microphone a session records, and can change it while recording. The capture never changes microphone silently: either the user asked for it, or the system imposed it and the user is told.

## Before this feature

`CoreAudioCapture` recorded the system default input, read once at start. Any change of the default input or output device was a `CaptureFault.routeChanged`: the session stopped (interrupted, audio kept). Connecting AirPods during a meeting therefore ended the session.

## Principles

- The capture records a **chosen microphone**, identified by its device UID, not "whatever the default input is".
- A change of the system default input is, at most, an **offer**. It never stops the session and never switches by itself.
- The capture switches without asking only when the microphone in use **disappears**. The user is told.
- Every switch is a **capture boundary**, stored with its reason and the microphone used from then on.

## What the user sees

### Choosing the microphone

- **New session**: a microphone picker. Default: the last microphone chosen, if present; otherwise the system default input.
- **Capture screen**: the same picker, showing the microphone in use. Choosing another microphone switches immediately (reason `user`).
- Devices appear and disappear from the picker as they are connected or removed. A device that appears without becoming the system default input is only added to the picker.

### Offer: the system default input changes

When the system default input moves to a device other than the one in use (typical case: AirPods connect and macOS picks them), HWYD posts a **system notification** with two actions:

> **Nouveau micro disponible : AirPods de Antoine**
> Basculer l'enregistrement sur ce micro ?
> [Basculer] [Garder <micro actuel>]

- A system notification, not an in-app window: during a meeting the user is in the meeting app, not in HWYD.
- **Basculer** switches (reason `accepted`). **Garder**, dismissing, or no answer keeps the current microphone.
- One offer per device change. A newer change replaces a pending offer.
- For a Bluetooth headset, the body adds one line: using its microphone switches it to call mode, which lowers the sound quality the user hears.
- The same offer is shown in the capture screen while it is pending, so the user who is in HWYD can answer there.

### Forced switch: the microphone in use disappears

- The capture switches to the system default input (reason `forced`) and posts a notice: « Le micro <ancien> n'est plus disponible. L'enregistrement continue sur <nouveau>. »
- If no input device is left, the session stops as interrupted, audio kept. It can be resumed once a microphone is back ([session resume](session-resume.md)).

### Output device changes

A change of the default output device (AirPods connecting also become the output) is imposed by the system and does not concern the microphone choice. It must not stop the session. Whether the global process tap follows the new output by itself or must be rebuilt is a **spike** (see below). If it must be rebuilt, the rebuild is silent and framed by `restarting` / `restarted(gap:)` like a microphone restart.

## Capture

### Port

`AudioCapture` gains:

- `microphones: [MicrophoneDevice]` (UID, name, transport such as built-in, USB, Bluetooth) and change notifications through `events`.
- `start(session:microphone:…)`: the chosen microphone UID (nil = system default input), in addition to the resume parameters.
- `switchMicrophone(to uid: String, reason: MicrophoneSwitchReason) async throws`.
- Events:
  - `microphonesChanged([MicrophoneDevice])`
  - `microphoneOffered(MicrophoneDevice)`: the system default input moved to this device.
  - `microphoneSwitched(MicrophoneDevice, reason)`: framed by `restarting` and `restarted(gap:)`.
- `CaptureFault.routeChanged` is removed. A new fault `noMicrophone` covers the case where no input is left.

`SimulatedCapture` simulates a list of microphones, offers and disappearances, so UI checks and tests never open a device.

### Adapter

- `CoreAudioCapture` listens to `kAudioHardwarePropertyDevices` and `kAudioHardwarePropertyDefaultInputDevice` (property listeners on its own queue, not the 5 Hz poll), and to `kAudioDevicePropertyDeviceIsAlive` on the microphone in use.
- A switch rebuilds the graph: stop the IOProcs, drain the rings, destroy the aggregate, build it again with the new microphone in combined or split mode depending on the sample rates (a Bluetooth headset in call mode runs at 16 kHz), start again. New rings are allocated outside the realtime callback.
- `AudioWriter` becomes reconfigurable: new inputs and converters, clocks anchored again, same files and chunk sequence. Like a pause, the gap is left out of the audio timeline, so notes stay aligned.
- If the rebuild fails, the capture tries the previous microphone once, then reports `CaptureFault.restart`.

### Session

`CaptureSession` owns the policy:

- turns `microphoneOffered` into the offer (through `UserNotifier` for the in-app part, and the system notification posted by the app);
- calls `switchMicrophone` on the user's choice or acceptance;
- appends a `CaptureBoundary` on every `microphoneSwitched`;
- remembers the last chosen microphone UID in `SettingsStore`.

## Model

Shared with session resume: `Recording.boundaries: [CaptureBoundary]`, with `CaptureBoundary { offset: Double; at: Date; reason: resumed | user | accepted | forced; microphone: String? }`. The session's first microphone is stored as `Recording.microphone: String?`. Both fields are optional; earlier sessions decode unchanged, no migration (sessions are JSON payloads).

Exports and MCP: `capture_boundaries` (`offset_us`, `at`, `reason`, `microphone`) and `microphone` in the JSON export and `get_recording`. Markdown and transcript show only `resumed` boundaries (« Reprise à … »). A microphone switch shows no marker in the transcript in this version.

## Transcription

- The adaptive echo canceller is reset at every boundary: the acoustic path changes with the microphone.
- Diarization and voice identity still run in one pass over the whole track. A voice heard through two microphones may split into two clusters; the voice review already allows merging them. Per-boundary diarization is out of scope until the evaluation corpus shows it is needed.
- The voice memory channel stays `mic`. Exemplars are extracted per cluster as today; no change.

## Spikes

1. Does a global stereo process tap keep delivering system audio after the default output device changes, or must the tap aggregate be rebuilt?
2. Duration of a graph rebuild with a Bluetooth microphone (HFP negotiation can take more than a second), and behaviour when the headset is still negotiating.
3. Does `kAudioHardwarePropertyDefaultInputDevice` change reliably when AirPods connect, including when the user disabled automatic switching?

## Out of scope

- Following the system default input automatically without asking.
- A marker for microphone switches in the transcript, waveform or player.
- Recording two microphones at once.

## Checks

- Picker at start and during capture; the choice is remembered; fallback to the default input when the remembered microphone is absent.
- Offer on default input change: switch on accept; keep on refuse, dismiss or no answer; a newer change replaces the pending offer.
- Forced switch when the microphone disappears, with a notice; interruption when no input is left.
- Output change does not stop the session.
- Combined to split mode and back across a switch (built-in to Bluetooth headset).
- Audio timeline: no gap, notes aligned, one boundary per switch with its reason and microphone; chunk files continue their sequence.
- Echo canceller reset at boundaries.
- Synthetic: `SimulatedCapture` covers offers, switches and disappearance; no microphone opened in `--demo`, `--snapshot`, `--self-test`, `--ui-test`, `--asr-test`.

## Implementation notes

- **Port.** As specified, with two additions: `microphone` returns a `MicrophoneDevice` (not only its name), and `microphoneLost(MicrophoneDevice)` is an event. The adapter does not pick the replacement itself: it reports the loss with the stream stopped, and `CaptureSession` switches to the default input (`forced`) or stops with `noMicrophone`, so the whole policy lives in the session.
- **Before a capture.** The setup screen needs the inputs before any capture exists, so `CaptureSource` carries a `MicrophoneCatalog` (`CoreAudioMicrophones` in the installed app, `FixedMicrophones` elsewhere). The remembered microphone is the last one the user chose in a picker or accepted; a forced switch does not change it, and a capture started from the shortcut or a calendar reminder uses it too.
- **Offer in the app.** The pending offer shows in the capture screen (and the detached notepad), not as a toast: the system notification already reaches the user wherever they are, and a second in-app copy would ask twice.
- **Pause.** A switch while paused rebuilds the graph without starting it, records the boundary at the paused time, and the clock stays frozen.
- **Output change.** Handled defensively until spike 1 is run: the tap and the graph are rebuilt on the same microphone, framed by `restarting` / `restarted(gap:)`, with no boundary.
- **Notifications.** One `UNUserNotificationCenter` delegate (`SystemNotifications`) now serves the calendar reminders and the microphone notices; clearing reminders no longer removes the microphone notices. Only the instance that owns the system services (the installed app on its own data, not a `--demo` instance next to it) takes the delegate and posts. The permission to notify is asked with the first notice (an offer or a forced switch), not when a capture starts: the microphone's permission is asked then, and two prompts at once would leave the user to guess which one matters. When it is refused, the offer still shows in the capture screen. While the frontmost HWYD shows the offer (capture screen or notepad), the notification goes to the Notification Center without a banner, so the question is not asked twice.
- **Remembered microphone.** `CaptureSession` resolves it: a capture started or resumed without a choice records the remembered microphone when present, else the system default input; the setup screen preselects `preferredMicrophone(in:)`. A choice is remembered once the capture records it, not when it is asked for or refused.
- **Device changes.** `CaptureDevices` (HWYDCore) decides what a look at the devices means: report the list, lose the microphone in use, rebuild the tap for a new output, offer a new default input. A switch asked by the session reads the devices without moving the reference the checks compare with, so a change it saw first is still reported and offered. When the microphone is lost together with an output change (AirPods unplugged), the forced switch builds the tap again and no other rebuild follows. `DeviceCheckGate` runs one check or rebuild at a time: a notification during a rebuild (our own aggregate, a headset changing mode) never cancels it, it causes one more check once the rebuild ends. The microphone that stops being alive is checked at once, not after the 500 ms settling delay.
- **Lost buffers.** Lost buffers or a stalled stream first look at the devices: when the microphone in use is going away, it is a loss for the session to replace, and buffers its rings lost on the way are forgiven when they are detached. The gap of a lost microphone starts at its last buffer, so in split mode the system audio that came after it, which the writer drops, is skipped by the clock too.
- **Order of events.** `microphoneSwitched` follows `restarted(gap:)`, so the boundary is dated on the corrected clock. A pause ends a restart in progress with `restarted(gap:)`. A graph built while paused, or paused before its first buffers, is waited for (8 s) when recording resumes, before the session clock runs: a Bluetooth headset still switching to call mode does not trip the 3 s stall check.
- **Picker.** Only inputs the graph accepts are listed: one input stream, 1 to 14 channels, 32-bit float PCM, not an aggregate device. A forced switch never lands on another one. The setup screen reads them off the main thread.
