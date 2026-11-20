#ifndef RTAtomic_h
#define RTAtomic_h

#include <stdint.h>

typedef struct MixerAtomics MixerAtomics;

MixerAtomics *mixer_atomics_create(float gain);
void mixer_atomics_destroy(MixerAtomics *state);
float mixer_gain_load(const MixerAtomics *state);
void mixer_gain_store(MixerAtomics *state, float gain);
void mixer_callback_mark(MixerAtomics *state);
uint32_t mixer_callback_count(const MixerAtomics *state);
void mixer_render_fail(MixerAtomics *state);
uint32_t mixer_render_failed(const MixerAtomics *state);

void mixer_signal_mark(MixerAtomics *state);
uint32_t mixer_signal_present(const MixerAtomics *state);
void mixer_playback_enable(MixerAtomics *state);
uint32_t mixer_playback_enabled(const MixerAtomics *state);

#endif
