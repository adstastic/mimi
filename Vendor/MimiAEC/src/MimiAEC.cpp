#include "MimiAEC.h"

#include <algorithm>

#include <webrtc/modules/audio_processing/include/audio_processing.h>

struct MimiAECProcessor {
    rtc::scoped_refptr<webrtc::AudioProcessing> audio_processing;
};

MimiAECProcessor *MimiAECCreate(void) {
    auto audio_processing = webrtc::AudioProcessingBuilder().Create();
    if (!audio_processing) {
        return nullptr;
    }

    webrtc::AudioProcessing::Config config;
    config.echo_canceller.enabled = true;
    config.echo_canceller.mobile_mode = false;
    config.echo_canceller.enforce_high_pass_filtering = false;

    // Echo cancellation is the only enabled AudioProcessing component.
    config.high_pass_filter.enabled = false;
    config.noise_suppression.enabled = false;
    config.gain_controller1.enabled = false;
    config.gain_controller2.enabled = false;
    config.pre_amplifier.enabled = false;
    config.capture_level_adjustment.enabled = false;
    config.transient_suppression.enabled = false;

    audio_processing->ApplyConfig(config);
    return new MimiAECProcessor{std::move(audio_processing)};
}

void MimiAECDestroy(MimiAECProcessor *processor) {
    delete processor;
}

size_t MimiAECFrameSize(int32_t sample_rate_hz) {
    if (sample_rate_hz < 8000 || sample_rate_hz > 384000) {
        return 0;
    }
    return webrtc::AudioProcessing::GetFrameSize(sample_rate_hz);
}

bool MimiAECProcessRender(
    MimiAECProcessor *processor,
    float *samples,
    size_t sample_count,
    int32_t sample_rate_hz
) {
    if (!processor || !samples || sample_count != MimiAECFrameSize(sample_rate_hz)) {
        return false;
    }

    const webrtc::StreamConfig config(sample_rate_hz, 1);
    const float *input[] = {samples};
    float *output[] = {samples};
    return processor->audio_processing->ProcessReverseStream(input, config, config, output)
        == webrtc::AudioProcessing::kNoError;
}

bool MimiAECProcessCapture(
    MimiAECProcessor *processor,
    float *samples,
    size_t sample_count,
    int32_t sample_rate_hz,
    int32_t stream_delay_ms
) {
    if (!processor || !samples || sample_count != MimiAECFrameSize(sample_rate_hz)) {
        return false;
    }

    processor->audio_processing->set_stream_delay_ms(std::clamp(stream_delay_ms, 0, 500));
    const webrtc::StreamConfig config(sample_rate_hz, 1);
    const float *input[] = {samples};
    float *output[] = {samples};
    return processor->audio_processing->ProcessStream(input, config, config, output)
        == webrtc::AudioProcessing::kNoError;
}
