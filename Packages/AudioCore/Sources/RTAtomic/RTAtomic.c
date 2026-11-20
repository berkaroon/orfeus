#include "RTAtomic.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "audio controls require lock-free atomics");
_Static_assert(sizeof(uint32_t) == sizeof(unsigned), "expected 32-bit unsigned int");
_Static_assert(sizeof(float) == sizeof(uint32_t), "expected 32-bit floating point");

struct MixerAtomics {
    atomic_uint gain;
    atomic_uint callbacks;
    atomic_uint failed;
    atomic_uint signal;
    atomic_uint playback;
};

MixerAtomics *mixer_atomics_create(float gain) {
    MixerAtomics *state = malloc(sizeof(*state));
    if (state == NULL) {
        return NULL;
    }
    uint32_t bits;
    memcpy(&bits, &gain, sizeof(bits));
    atomic_init(&state->gain, bits);
    atomic_init(&state->callbacks, 0);
    atomic_init(&state->failed, 0);
    atomic_init(&state->signal, 0);
    atomic_init(&state->playback, 0);
    return state;
}

void mixer_atomics_destroy(MixerAtomics *state) {
    free(state);
}

float mixer_gain_load(const MixerAtomics *state) {
    uint32_t bits = atomic_load_explicit(&state->gain, memory_order_relaxed);
    float gain;
    memcpy(&gain, &bits, sizeof(gain));
    return gain;
}

void mixer_gain_store(MixerAtomics *state, float gain) {
    uint32_t bits;
    memcpy(&bits, &gain, sizeof(bits));
    atomic_store_explicit(&state->gain, bits, memory_order_relaxed);
}

void mixer_callback_mark(MixerAtomics *state) {
    atomic_fetch_add_explicit(&state->callbacks, 1, memory_order_relaxed);
}

uint32_t mixer_callback_count(const MixerAtomics *state) {
    return atomic_load_explicit(&state->callbacks, memory_order_relaxed);
}

void mixer_render_fail(MixerAtomics *state) {
    atomic_store_explicit(&state->failed, 1, memory_order_relaxed);
}

uint32_t mixer_render_failed(const MixerAtomics *state) {
    return atomic_load_explicit(&state->failed, memory_order_relaxed);
}

void mixer_signal_mark(MixerAtomics *state) {
    atomic_store_explicit(&state->signal, 1, memory_order_relaxed);
}

uint32_t mixer_signal_present(const MixerAtomics *state) {
    return atomic_load_explicit(&state->signal, memory_order_relaxed);
}

void mixer_playback_enable(MixerAtomics *state) {
    atomic_store_explicit(&state->playback, 1, memory_order_relaxed);
}

uint32_t mixer_playback_enabled(const MixerAtomics *state) {
    return atomic_load_explicit(&state->playback, memory_order_relaxed);
}
