#include "hwyd_echo.h"
#include "speex/speex_echo.h"
#include "speex/speex_preprocess.h"
#include <stdlib.h>
struct HWYDEcho { SpeexEchoState *echo; SpeexPreprocessState *residual; };
HWYDEcho *hwyd_echo_create(void) {
    HWYDEcho *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    state->echo = speex_echo_state_init(256, 8192);
    if (!state->echo) { free(state); return NULL; }
    int rate = 16000;
    speex_echo_ctl(state->echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate);
    state->residual = speex_preprocess_state_init(256, rate);
    if (!state->residual) { speex_echo_state_destroy(state->echo); free(state); return NULL; }
    int noise = 0, echo = -45, active = -12;
    speex_preprocess_ctl(state->residual, SPEEX_PREPROCESS_SET_NOISE_SUPPRESS, &noise);
    speex_preprocess_ctl(state->residual, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS, &echo);
    speex_preprocess_ctl(state->residual, SPEEX_PREPROCESS_SET_ECHO_SUPPRESS_ACTIVE, &active);
    speex_preprocess_ctl(state->residual, SPEEX_PREPROCESS_SET_ECHO_STATE, state->echo);
    return state;
}
void hwyd_echo_destroy(HWYDEcho *state) {
    if (!state) return;
    speex_echo_state_destroy(state->echo);
    speex_preprocess_state_destroy(state->residual);
    free(state);
}
void hwyd_echo_process(HWYDEcho *state, const int16_t *mic, const int16_t *reference, int16_t *output) {
    speex_echo_cancellation(state->echo, mic, reference, output);
    speex_preprocess_run(state->residual, output);
}
