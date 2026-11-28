#include "HWYDRealtime.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static void submit(HWYDRing *ring, AudioBufferList *input, uint64_t time) {
    AudioTimeStamp stamp = {0}; stamp.mHostTime = time;
    AudioBufferList output = {0};
    HWYDIOProc(0, &stamp, input, &stamp, &output, &stamp, ring);
}
int main(void) {
    HWYDRing *ring = HWYDRingCreate(3); assert(ring);
    AudioBufferList *input = calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer));
    float mic[16], system[32], result[48]; uint64_t time = 0;
    for (int i = 0; i < 16; i++) { mic[i] = i; system[2*i] = 100+i; system[2*i+1] = 200+i; }
    input->mNumberBuffers = 2;
    input->mBuffers[0] = (AudioBuffer){1, sizeof(mic), mic};
    input->mBuffers[1] = (AudioBuffer){2, sizeof(system), system};
    submit(ring, input, 123);
    assert(HWYDRingRead(ring, result, &time) == 16 && time == 123);
    for (int i = 0; i < 16; i++) { assert(result[3*i] == i); assert(result[3*i+1] == 100+i); assert(result[3*i+2] == 200+i); }
    input->mBuffers[1].mDataByteSize -= 8;
    submit(ring, input, 124);
    assert(HWYDRingDropped(ring) == 1 && HWYDRingRead(ring, result, &time) == 0);
    input->mBuffers[1].mDataByteSize = sizeof(system);
    input->mBuffers[1].mData = NULL;
    submit(ring, input, 125);
    assert(HWYDRingRead(ring, result, &time) == 16);
    for (int i = 0; i < 16; i++) { assert(result[3*i] == i); assert(result[3*i+1] == 0 && result[3*i+2] == 0); }
    for (int i = 0; i < 65; i++) submit(ring, input, i);
    assert(HWYDRingDropped(ring) == 2);
    for (int i = 0; i < 64; i++) { assert(HWYDRingRead(ring, result, &time) == 16 && time == (uint64_t)i); }
    assert(HWYDRingRead(ring, result, &time) == 0);
    // Exercise wrap-around repeatedly without changing the allocation footprint.
    for (int i = 0; i < 100000; i++) { submit(ring, input, i); assert(HWYDRingRead(ring, result, &time) == 16 && time == (uint64_t)i); }
    assert(HWYDRingDropped(ring) == 2);
    assert(HWYDRingDropReason(ring, 1) == 1 && HWYDRingDropReason(ring, 3) == 1);
    // A device that changes its channel count is told apart from a frame size the ring cannot hold.
    input->mNumberBuffers = 1;
    submit(ring, input, 1);
    assert(HWYDRingDropReason(ring, 4) == 1 && HWYDRingDropReason(ring, 2) == 0);
    input->mNumberBuffers = 2;
    input->mBuffers[0] = (AudioBuffer){2, sizeof(mic), mic};
    submit(ring, input, 2);
    assert(HWYDRingDropReason(ring, 0) == 1);
    input->mBuffers[0] = (AudioBuffer){1, 0, mic};
    input->mBuffers[1] = (AudioBuffer){2, 0, system};
    submit(ring, input, 3);
    assert(HWYDRingDropReason(ring, 2) == 1 && HWYDRingDropReason(ring, 4) == 1);
    assert(HWYDRingDropped(ring) == 5 && HWYDRingRead(ring, result, &time) == 0);
    HWYDRingDestroy(ring); free(input);
    puts("Ring split buffers, silent tap, malformed buffers, channel count, overflow and wrap-around: PASS");
}
