#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

typedef struct HWYDRing HWYDRing;
HWYDRing *_Nullable HWYDRingCreate(uint32_t channels);
void HWYDRingDestroy(HWYDRing *_Nonnull ring);
uint32_t HWYDRingRead(HWYDRing *_Nonnull ring, float *_Nonnull output, uint64_t *_Nonnull hostTime);
uint64_t HWYDRingDropped(HWYDRing *_Nonnull ring);
/// Buffers refused for `reason`: 0 more channels than the ring, 1 buffers of one delivery disagree on their frame
/// count, 2 no frame or more than the ring holds, 3 ring full, 4 fewer channels than the ring.
uint64_t HWYDRingDropReason(HWYDRing *_Nonnull ring, uint32_t reason);
OSStatus HWYDIOProc(AudioDeviceID device, const AudioTimeStamp *_Nonnull now,
    const AudioBufferList *_Nonnull input, const AudioTimeStamp *_Nonnull inputTime,
    AudioBufferList *_Nonnull output, const AudioTimeStamp *_Nonnull outputTime, void *_Nullable context);
