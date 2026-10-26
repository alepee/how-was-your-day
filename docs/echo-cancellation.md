# Offline echo cancellation

Dual-track transcription now applies an adaptive acoustic echo canceller before ASR and diarization. Capture stays raw. The system track is the reference; only a disposable microphone copy is processed. Both recognizers retain the original session timestamps. Original CAF chunks, playback and previous transcript revisions remain unchanged.

## Implementation

| Property | Value |
| --- | --- |
| Engine | SpeexDSP 1.2.1, floating-point MDF with Kiss FFT |
| Input | 16 kHz mono, synchronized microphone and system capture |
| Frame | 256 samples, 16 ms |
| Adaptive filter | 8,192 samples, 512 ms |
| Residual suppression | Speex spectral echo suppression: -45 dB maximum, -24 dB during local speech; noise suppression 0 dB, AGC off |
| Placement | Pipeline process, before ASR and per-track diarization |
| Provenance | Optional `echoCancellationEngine` in result and recording transcription metadata |
| Bypass | Single-track sessions, or explicit `echoCancellation: false` in a CLI request |
| Failures | Fail the job; never silently label raw input as echo-cancelled |

Assembly fills timeline gaps with silence. Filter state survives CAF boundaries. The residual suppressor adds 256 samples of latency; processing discards the first frame and flushes the tail to compensate it. Processed chunks have the same start and sample count as the originals. Diarization uses the complete processed microphone file. Temporary audio is removed when the job exits normally. Abrupt process termination can leave the job directory for later cleanup, like other pipeline work files.

This is an amendment to the diagnostic-only correlation step in `architecture.md`. A correlation gate alone cannot separate local speech from simultaneous playback. An adaptive filter estimates the acoustic path and subtracts the reference contribution. This does not guarantee perfect separation, particularly with nonlinear loudspeakers, clipped inputs, changing devices or delays beyond the filter tail. Existing transcripts are not rewritten on upgrade. Reprocessing creates a new transcript version and invalidates the previous summary.

## Third-party source

Source: https://downloads.xiph.org/releases/speex/speexdsp-1.2.1.tar.gz

SHA-256: `8c777343e4a6399569c72abc38a95b24db56882c83dbdb6c6424a5f4aeb54d3d`

The selected C sources and headers under `Sources/HWYDEcho/vendor` are unchanged. `speexdsp_config_types.h` supplies fixed-width standard C integer types. SwiftPM defines `FLOATING_POINT`, `USE_KISS_FFT` and an empty `EXPORT`. No system Homebrew dependency is required. The BSD license is bundled in `Resources/Licenses/SpeexDSP.txt`; individual source notices, including Kiss FFT, are retained.

Reference API: https://www.speex.org/docs/api/speex-api-reference/group__SpeexEchoState.html

## Validation

Synthetic regression tests cover delayed reverberant echo, simultaneous independent local speech, silent/short reference audio and non-frame-aligned EOF. Real-session validation artifacts belong in ignored `build/echo-validation`, never in the public repository. Synthetic energy reduction is not a real-world WER guarantee.

## Residual echo review, v2

The v2 engine increases residual suppression during detected local speech from -12 to -24 dB. It does not shift either timeline or extend the acoustic filter tail. An isolated 8-minute comparison used three 160-second extracts from one real speakerphone session. Counting matching runs of at least three words between microphone and system transcripts dropped from 122 to 68 repeated words. This is a duplication proxy, not annotated WER or a guarantee that local speech is unchanged. Long local turns were substantially unchanged on inspection; some short fragments differed. The independent synthetic double-talk check retained a near-end gain of approximately 0.90 with both settings.

Audio correlation over the reported problem intervals found peaks around 5-10 ms, not the apparent 1-5 second separation between transcript segments. Long system segments and short microphone fragments have different boundaries. A difference between segment starts must not be treated as an acoustic delay estimate. Changing the capture timestamps based on those text boundaries would damage alignment.

After ASR and diarization, `EchoTranscriptGuard` annotates microphone fragments with `echoSuspect`. It requires at least six words, a substantial text length and a strong contiguous approximate match in nearby system speech (within five seconds). Short acknowledgements and isolated words are not marked. Confirmed speaker identity does not exempt a fragment from the check. Adjacent system segments can be compared together when separated by at most one second.

The flag is a review hint, not proof: a person can intentionally repeat a remote participant. Annotation never deletes words, changes timestamps, clears identity, or merges speakers. A `nil` value on older transcripts means not evaluated; `false` means evaluated without a match. The conservative first version marked four of 854 segments in the original reviewed transcript, including a repeated phrase already assigned to a known local person. Many corrupted or short echoes remain unmarked. Consumers must not interpret an unmarked segment as verified clean speech.

The optional `HWYD_ECHO_REVIEW_RECORDING` XCTest fixture writes a separately identified annotated JSON copy beside the supplied fixture. Real audio and transcripts remain in ignored `build/echo-review-test`. They must never be committed to this public repository.
