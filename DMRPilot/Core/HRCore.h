//
//  HRCore.h
//  DMRPilot
//
//  AMBE+2 半速率声码器（DMR 用的那种）的 C 接口。
//
//  实现不是新写的：`Core/Vocoder/` 下那 16 个 .cc / 14 个 .h 是 DroidStar 的
//  `mbe/halfrate` 子系统原文件（GPL-3.0-or-later），也就是 DroidStar iOS 版
//  实际在用的那份解码器 —— `MBEVocoder::decode_2450x1150()` 里第一行就是
//  `ambe2_decode_packed()`，最终落到 `hr_decode_air()`。之前那套 Swift 移植
//  （HalfrateDecoder/Dequant/Synth/Fec）虽然也是从同一份源码搬的，但定点到浮点、
//  码本索引、相位累加这些地方只要错一位，听感就会变成噪音，且没有真机无法比对。
//  直接把原文件编进来就没有这层风险。
//
//  和 DMRCore / RewindCore 一样：这层只做字节处理，不碰网络、线程与内存分配策略。
//
//  ── 数据流 ──────────────────────────────────────────────────────────
//
//      DMRD 33 字节载荷 ──(DMRCore 拆帧)──▶ 27 字节 codec
//                                            │  9 + 9 + 9，每 9 字节是一个
//                                            │  带 FEC 与交织的空中帧
//                                            ▼
//                                     hrd_decode_packet()
//                                            │  内部对每 9 字节做
//                                            │  Golay(23,12) 纠错 → 49 bit 参数
//                                            ▼
//                                     3 × 160 = 480 个 8 kHz PCM
//
//  ODTP/Rewind 那条链路更直接：0x0920 的载荷本身就是这 27 字节，一步到这儿。
//

#ifndef HR_CORE_H
#define HR_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 不透明句柄。一个通话一路，内部保存预测器与合成器的跨帧状态。
typedef struct hrd_decoder hrd_decoder_t;

/// 每个帧 20 ms / 160 采样，每个 DMR 突发三帧。
/// 注意都写成字面量：Swift 只导入「单个字面量」形式的宏，表达式宏会找不到。
#define HRD_SAMPLES_PER_FRAME   160
#define HRD_FRAMES_PER_PACKET   3
#define HRD_SAMPLES_PER_PACKET  480
#define HRD_AIR_BYTES           9

/// hrd_decode_* 的返回值：这一帧是什么。
#define HRD_KIND_VOICE     0   ///< 正常语音
#define HRD_KIND_SILENCE   1   ///< 静音帧（背景电平）
#define HRD_KIND_TONE      2   ///< 单音 / 双音（键盘、呼叫进程音）
#define HRD_KIND_ERASURE   3   ///< 纠错失败：重复上一帧 → 静音 → 舒适噪声

/// 出错时的返回值（与上面四个不冲突）。
#define HRD_ERROR         -1

// MARK: - 生命周期

/// 新建一个解码器（已按 DroidStar 的听感参数预设好）。
hrd_decoder_t* hrd_create(void);

void hrd_destroy(hrd_decoder_t* decoder);

/// 回到初始状态，保留音频参数。切换通话 / 重连时调用。
void hrd_reset(hrd_decoder_t* decoder);

// MARK: - 解码

/// 一个 9 字节空中帧 → 160 采样。返回 HRD_KIND_*，失败返回 HRD_ERROR。
///
/// `out_errors`（可为 NULL）收到这一帧 Golay(23,12) 纠正的比特数；-1 表示不可纠错。
int32_t hrd_decode_frame(hrd_decoder_t* decoder,
                         const uint8_t* air9,
                         int16_t* pcm160,
                         int32_t* out_errors);

/// 一个 27 字节 codec（3 帧）→ 480 采样。
///
/// 返回值取三帧里「最坏」的那个：只要有一帧不可纠错就是 HRD_KIND_ERASURE，
/// 调用方可以据此统计丢帧率。失败（参数为空）返回 HRD_ERROR。
/// `out_errors`（可为 NULL）收到三帧纠错比特数之和。
int32_t hrd_decode_packet(hrd_decoder_t* decoder,
                          const uint8_t* codec27,
                          int16_t* pcm480,
                          int32_t* out_errors);

// MARK: - 调音

/// 按名字改一个参数（`output_gain`、`enhance_strength` 等，见 DroidStar 的
/// `docs/options.md`）。成功返回 0，名字不认识或值非法返回 -1。
/// 一般不需要动：默认值就是 DroidStar 对着 DVSI 声码棒拟合出来的那组。
int32_t hrd_set_option(hrd_decoder_t* decoder, const char* name, double value);

#ifdef __cplusplus
}
#endif

#endif // HR_CORE_H
