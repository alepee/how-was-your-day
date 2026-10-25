#include "HWYDRealtime.h"
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#define CAPACITY 64
#define MAX_FRAMES 4096
struct HWYDRing {
    uint32_t channels;
    _Atomic uint64_t readIndex, writeIndex, dropped;
    uint32_t frames[CAPACITY];
    uint64_t timestamps[CAPACITY];
    float *samples;
};
HWYDRing *HWYDRingCreate(uint32_t channels) {
    if (!channels || channels > 16) return NULL;
    HWYDRing *r = calloc(1, sizeof(HWYDRing));
    if (!r) return NULL;
    r->channels = channels;
    r->samples = calloc(CAPACITY * MAX_FRAMES * channels, sizeof(float));
    if (!r->samples) { free(r); return NULL; }
    return r;
}
void HWYDRingDestroy(HWYDRing *r) { if (r) { free(r->samples); free(r); } }
uint64_t HWYDRingDropped(HWYDRing *r) { return atomic_load_explicit(&r->dropped, memory_order_relaxed); }
OSStatus HWYDIOProc(AudioDeviceID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    HWYDRing *r = context;
    if (!r || !input || !input->mNumberBuffers) return noErr;
    uint32_t channels = 0, frames = UINT32_MAX;
    for (uint32_t b = 0; b < input->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        if (buffer->mNumberChannels > r->channels - channels) {
            atomic_fetch_add_explicit(&r->dropped, 1, memory_order_relaxed); return noErr;
        }
        channels += buffer->mNumberChannels;
        if (buffer->mNumberChannels && buffer->mData) {
            uint32_t stride = sizeof(float) * buffer->mNumberChannels;
            uint32_t f = buffer->mDataByteSize / stride;
            // Never silently shorten one track when HAL delivers inconsistent buffers.
            if (buffer->mDataByteSize % stride || (frames != UINT32_MAX && frames != f)) {
                atomic_fetch_add_explicit(&r->dropped, 1, memory_order_relaxed); return noErr;
            }
            frames = f;
        }
    }
    uint64_t w = atomic_load_explicit(&r->writeIndex, memory_order_relaxed);
    if (channels != r->channels || !frames || frames > MAX_FRAMES ||
        w - atomic_load_explicit(&r->readIndex, memory_order_acquire) >= CAPACITY) {
        atomic_fetch_add_explicit(&r->dropped, 1, memory_order_relaxed); return noErr;
    }
    uint32_t slot = w % CAPACITY, offset = 0;
    float *dest = r->samples + slot * MAX_FRAMES * channels;
    for (uint32_t b = 0; b < input->mNumberBuffers; b++) {
        const AudioBuffer *buffer = &input->mBuffers[b];
        const float *source = buffer->mData;
        for (uint32_t f = 0; f < frames; f++)
            for (uint32_t c = 0; c < buffer->mNumberChannels; c++)
                dest[f * channels + offset + c] = source ? source[f * buffer->mNumberChannels + c] : 0;
        offset += buffer->mNumberChannels;
    }
    r->frames[slot] = frames; r->timestamps[slot] = inputTime->mHostTime;
    atomic_store_explicit(&r->writeIndex, w + 1, memory_order_release);
    return noErr;
}
uint32_t HWYDRingRead(HWYDRing *r, float *output, uint64_t *hostTime) {
    uint64_t read = atomic_load_explicit(&r->readIndex, memory_order_relaxed);
    if (read == atomic_load_explicit(&r->writeIndex, memory_order_acquire)) return 0;
    uint32_t slot = read % CAPACITY, frames = r->frames[slot];
    memcpy(output, r->samples + slot * MAX_FRAMES * r->channels, frames * r->channels * sizeof(float));
    *hostTime = r->timestamps[slot];
    atomic_store_explicit(&r->readIndex, read + 1, memory_order_release);
    return frames;
}
