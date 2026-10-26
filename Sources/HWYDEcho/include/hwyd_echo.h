#ifndef HWYD_ECHO_H
#define HWYD_ECHO_H
#include <stdint.h>
typedef struct HWYDEcho HWYDEcho;
HWYDEcho *hwyd_echo_create(void);
void hwyd_echo_destroy(HWYDEcho *state);
// Exactly 256 samples, 16 kHz mono. Offline processing only.
void hwyd_echo_process(HWYDEcho *state, const int16_t *mic, const int16_t *reference, int16_t *output);
#endif
