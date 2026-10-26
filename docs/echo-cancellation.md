# Offline echo cancellation

Dual-track transcription now applies an adaptive acoustic echo canceller before ASR and diarization. Capture stays raw. The system track is the reference; only a disposable microphone copy is processed. Both recognizers retain the original session timestamps. Original CAF chunks, playback and previous transcript revisions remain unchanged.

## Implementation

| Property | Value |
| --- | --- |
| Engine | SpeexDSP 1.2.1, floating-point MDF with Kiss FFT |
| Input | 16 kHz mono, synchronized microphone and system capture |
| Frame | 256 samples, 16 ms |
| Adaptive filter | 8,192 samples, 512 ms |
| Residual suppression | Speex spectral echo suppression: -45 dB maximum, -12 dB during local speech; noise suppression 0 dB, AGC off |
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
