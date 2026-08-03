#ifndef MIMI_AEC_H
#define MIMI_AEC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MimiAECProcessor MimiAECProcessor;

MimiAECProcessor *MimiAECCreate(void);
void MimiAECDestroy(MimiAECProcessor *processor);

size_t MimiAECFrameSize(int32_t sample_rate_hz);

bool MimiAECProcessRender(
    MimiAECProcessor *processor,
    float *samples,
    size_t sample_count,
    int32_t sample_rate_hz
);

bool MimiAECProcessCapture(
    MimiAECProcessor *processor,
    float *samples,
    size_t sample_count,
    int32_t sample_rate_hz,
    int32_t stream_delay_ms
);

#ifdef __cplusplus
}
#endif

#endif
