//
//  HRCore.cpp
//  DMRPilot
//
//  AMBE+2 半速率解码器的 C 接口实现。真正干活的在 `Vocoder/` 那套 DroidStar
//  原文件里，这里只负责：建对象、套上 DroidStar 的听感参数、把 27 字节拆成三帧。
//
//  许可证：Vocoder/ 下的文件来自 DroidStar 的 mbe/halfrate（GPL-3.0-or-later）。
//

#include "HRCore.h"

#include <cstdlib>
#include <cstring>

#include "Vocoder/halfrate.h"

struct hrd_decoder {
    hr_decoder* core;
};

// DroidStar 的 `ambe2.cc` 里那组参数：对着 DVSI 声码棒在训练集上拟合出来的
// （2026-10-28 的实测，见 ambe2.cc 注释）。halfrate 自己的默认值不是这个 ——
// 少了这 12 行，声音会明显偏薄、擦除帧的高频也不对，所以必须照抄。
//
//   输出增益 2.07 / 高频倾斜 0.5（从 0.66L 起） / 静音增益 0.26
//   共振峰增强 0.61（权重 0.39…1.24，分界 460 Hz，高频 0.72 / 低频 0.2）
//   混合浊音占比 1.0 / 重复帧高频 +1.78
static const struct {
    const char* name;
    double value;
} kDecoderTuning[] = {
    {"output_gain", 2.07},
    {"high_band_tilt", 0.5},
    {"high_band_start", 0.66},
    {"silence_gain", 0.26},
    {"enhance_strength", 0.61},
    {"enhance_min_weight", 0.39},
    {"enhance_max_weight", 1.24},
    {"enhance_power_high", 0.72},
    {"enhance_power_low", 0.2},
    {"enhance_split_frequency", 0.057},
    {"mixed_voiced_share", 1.0},
    {"repeat_high_gain", 1.78},
};

extern "C" {

hrd_decoder_t* hrd_create(void) {
    hrd_decoder* d = static_cast<hrd_decoder*>(std::calloc(1, sizeof(hrd_decoder)));
    if (d == NULL) {
        return NULL;
    }
    d->core = hr_decoder_new();
    if (d->core == NULL) {
        std::free(d);
        return NULL;
    }
    for (int32_t i = 0; i < int32_t(sizeof(kDecoderTuning) / sizeof(kDecoderTuning[0])); i++) {
        hr_decoder_set(d->core, kDecoderTuning[i].name, kDecoderTuning[i].value);
    }
    return d;
}

void hrd_destroy(hrd_decoder_t* decoder) {
    if (decoder == NULL) {
        return;
    }
    if (decoder->core != NULL) {
        hr_decoder_free(decoder->core);
    }
    std::free(decoder);
}

void hrd_reset(hrd_decoder_t* decoder) {
    if (decoder == NULL || decoder->core == NULL) {
        return;
    }
    // 清掉跨帧预测、合成器相位、擦除计数与高通状态；调好的参数保留。
    hr_decoder_reset(decoder->core);
}

int32_t hrd_decode_frame(hrd_decoder_t* decoder, const uint8_t* air9, int16_t* pcm160,
                         int32_t* out_errors) {
    if (out_errors != NULL) {
        *out_errors = 0;
    }
    if (decoder == NULL || decoder->core == NULL || pcm160 == NULL) {
        return HRD_ERROR;
    }
    if (air9 == NULL) {
        // 整帧丢了：让解码器做擦除隐藏（重复 → 静音 → 舒适噪声），比补零好听得多。
        return int32_t(hr_decode(decoder->core, NULL, pcm160));
    }
    // hr_decode_air_errors：Golay(23,12) 纠错 + 解交织 → 49 bit 参数 → 160 采样。
    int errors = 0;
    const int32_t kind = int32_t(hr_decode_air_errors(decoder->core, air9, pcm160, &errors));
    if (out_errors != NULL) {
        *out_errors = int32_t(errors);
    }
    return kind;
}

int32_t hrd_decode_packet(hrd_decoder_t* decoder, const uint8_t* codec27, int16_t* pcm480,
                          int32_t* out_errors) {
    if (out_errors != NULL) {
        *out_errors = 0;
    }
    if (decoder == NULL || decoder->core == NULL || codec27 == NULL || pcm480 == NULL) {
        return HRD_ERROR;
    }

    int32_t worst = HRD_KIND_VOICE;
    int32_t total_errors = 0;
    for (int32_t i = 0; i < HRD_FRAMES_PER_PACKET; i++) {
        int errors = 0;
        const int32_t kind = int32_t(hr_decode_air_errors(decoder->core,
                                                          codec27 + i * HRD_AIR_BYTES,
                                                          pcm480 + i * HRD_SAMPLES_PER_FRAME,
                                                          &errors));
        if (kind < 0) {
            return HRD_ERROR;
        }
        total_errors += int32_t(errors);
        if (kind > worst) {
            worst = kind;
        }
    }
    if (out_errors != NULL) {
        *out_errors = total_errors;
    }
    return worst;
}

int32_t hrd_decode_plain(hrd_decoder_t* decoder, const uint8_t* frame7, int16_t* pcm160,
                         int32_t* out_errors) {
    if (out_errors != NULL) {
        *out_errors = 0;
    }
    if (decoder == NULL || decoder->core == NULL || pcm160 == NULL) {
        return HRD_ERROR;
    }
    // YSF 的 VD 模式 2 就是这样：FEC 已经在 13 字节 VCH 里解掉了（Golay/卷积/重复码），
    // 到这一步只剩干净的 49 bit 参数，直接进解码器，不用再过 DMR 那套 (23,12)。
    if (frame7 == NULL) {
        return int32_t(hr_decode(decoder->core, NULL, pcm160));
    }
    return int32_t(hr_decode(decoder->core, frame7, pcm160));
}

int32_t hrd_set_option(hrd_decoder_t* decoder, const char* name, double value) {
    if (decoder == NULL || decoder->core == NULL || name == NULL) {
        return -1;
    }
    return hr_decoder_set(decoder->core, name, value) ? 0 : -1;
}

}  // extern "C"
