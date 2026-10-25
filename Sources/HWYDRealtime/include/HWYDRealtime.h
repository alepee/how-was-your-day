#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>

typedef struct HWYDRing HWYDRing;
HWYDRing *_Nullable HWYDRingCreate(uint32_t channels);
void HWYDRingDestroy(HWYDRing *_Nonnull ring);
uint32_t HWYDRingRead(HWYDRing *_Nonnull ring, float *_Nonnull output, uint64_t *_Nonnull hostTime);
uint64_t HWYDRingDropped(HWYDRing *_Nonnull ring);
OSStatus HWYDIOProc(AudioDeviceID device, const AudioTimeStamp *_Nonnull now,
    const AudioBufferList *_Nonnull input, const AudioTimeStamp *_Nonnull inputTime,
    AudioBufferList *_Nonnull output, const AudioTimeStamp *_Nonnull outputTime, void *_Nullable context);
