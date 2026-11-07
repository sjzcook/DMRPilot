//
//  RewindCore.h
//  DMRPilot
//
//  BrandMeister 的 Open DMR Terminal Protocol（ODTP）/ Rewind 协议核心。
//
//  为什么需要它：BrandMeister 上的 DMR 有两条互不相通的入口
//
//      62031  Homebrew / MMDVM_HBP  —— 订阅靠「发一次真实发射」，没有订阅指令
//      54006  ODTP / Rewind        —— 订阅是显式命令，登录后直接 SUBSCRIBE
//
//  DroidStar 的 iOS 版（0.45.04 起）在 BrandMeister 上已经默认走 ODTP，
//  桌面版 dmr.cpp 仍然只有 Homebrew。这套代码按 BrandMeister 官方协议规范
//  （Open DMR Terminal Protocol / Rewind）实现，参考实现是 DigestPlay 的 ODMRTP 分支。
//
//  协议要点：
//    · UDP，小端字节序
//    · 每包 18 字节头：`REWIND01`(8) + type(2) + flags(2) + number(4) + length(2)
//    · 登录：KEEP_ALIVE(带 DMR ID + 服务类型) → CHALLENGE(盐)
//            → AUTHENTICATION(SHA256(盐‖密码)) → 空 KEEP_ALIVE
//    · 订阅：SUBSCRIPTION(type=7 组呼, number=TG) → 空 SUBSCRIPTION
//    · 语音：DMR_DATA_BASE+1 = 12 字节 Full LC，+2 = 结束符，
//            DMR_AUDIO_FRAME = 27 字节三帧 AMBE（mode 33，正好是解码器要的格式）
//
//  和 DMRCore 的分工：这一层同样只处理「字节」，不碰网络、线程与内存分配。
//

#ifndef REWIND_CORE_H
#define REWIND_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 不透明句柄。
typedef struct rewind_core rewind_core_t;

// 会话状态。
#define RW_STATUS_DISCONNECTED 0
#define RW_STATUS_CONNECTING   1   // 已发 KEEP_ALIVE，等挑战盐
#define RW_STATUS_AUTH         2   // 已发 AUTHENTICATION，等空 KEEP_ALIVE
#define RW_STATUS_SUBSCRIBING  3   // 已发 SUBSCRIPTION，等确认
#define RW_STATUS_CONNECTED    4   // 订阅成功，可以收发语音

// 处理完一个包之后调用方要做什么。
#define RW_EVT_NONE          0
#define RW_EVT_AUTH          1   // 收到挑战盐，回发 result->out（**已带 18 字节头的完整包**）
#define RW_EVT_AUTHENTICATED 2   // 鉴权通过，应发 SUBSCRIPTION
#define RW_EVT_SUBSCRIBED    3   // 订阅确认，进入 CONNECTED
#define RW_EVT_RX_HEADER     4   // 语音头（result->src / dst）
#define RW_EVT_RX_VOICE      5   // 语音帧（result->codec 里是 27 字节 AMBE）
#define RW_EVT_RX_EOT        6   // 结束符
#define RW_EVT_PONG          7   // 空 KEEP_ALIVE：心跳应答
#define RW_EVT_REPORT        8   // 服务器文本报告（result->payload 里是 UTF-8）
#define RW_EVT_CLOSED        9   // 服务器关闭连接
#define RW_EVT_FAILURE      10   // 服务器返回失败码（订阅被拒等，result->payload 前 4 字节）
#define RW_EVT_AUTH_REJECTED 11  // 服务器反复发挑战盐：密码不对，别再无谓重试
#define RW_EVT_REDIRECT     12   // 服务器要求改连另一台 master（result->payload 里是文本地址）

/// 一次收包的结果。
typedef struct {
    int32_t  event;          ///< RW_EVT_*
    int32_t  status;         ///< 处理完这个包之后的会话状态
    uint32_t src;            ///< 3 字节源地址（7 位 DMR ID）
    uint32_t dst;            ///< 3 字节目的地址（通话组或对方 ID）
    uint32_t number;         ///< Rewind 包序号
    int32_t  is_private;     ///< 1 = 单呼（LC 的 FLCO 为 3）
    int32_t  out_len;        ///< out 里有效的字节数
    uint8_t  codec[27];      ///< 语音帧的 27 字节 AMBE
    uint8_t  payload[160];   ///< 文本报告 / 原始数据
    uint8_t  out[64];        ///< 需要回发的**完整**包（AUTHENTICATION = 18 字节头 + 32 字节摘要）
} rw_result_t;

// MARK: - 生命周期

rewind_core_t* rw_core_create(void);
void           rw_core_destroy(rewind_core_t* core);

/// DMR ID 是 **7 位**的那个（不带热点后缀），密码是 SelfCare 里给热点设的。
void rw_core_set_identity(rewind_core_t* core, uint32_t dmr_id, const char* password);

/// 软件名与版本，会放进 KEEP_ALIVE 的 VersionData。
void rw_core_set_version(rewind_core_t* core, const char* version);

/// 退回未连接状态，保留身份信息。重连前调用。
void rw_core_reset(rewind_core_t* core);

int32_t rw_core_status(rewind_core_t* core);

// MARK: - 建链

/// KEEP_ALIVE（带 VersionData）。登录和心跳用的是同一个包。
int32_t rw_core_keepalive(rewind_core_t* core, uint8_t* out, int32_t cap);

/// SUBSCRIPTION：type=7 组呼，number=通话组。
int32_t rw_core_subscribe(rewind_core_t* core, uint32_t talkgroup, uint8_t* out, int32_t cap);

/// CANCELLING：退订全部。
int32_t rw_core_cancel(rewind_core_t* core, uint8_t* out, int32_t cap);

/// CLOSE：主动断开。
int32_t rw_core_close(rewind_core_t* core, uint8_t* out, int32_t cap);

// MARK: - 收包

int32_t rw_core_receive(rewind_core_t* core,
                        const uint8_t* in,
                        int32_t len,
                        rw_result_t* result);

// MARK: - 发射

/// 语音头：12 字节 Full LC（FLCO + FID + 服务选项 + 目的 + 源 + CRC）。
/// 和 DigestPlay 一样把 CRC 填 0 —— 服务端不校验，规范里也写明可以跳过计算。
/// 真实客户端会连发 2～3 次同样的头，调用方自己决定发几次。
int32_t rw_core_tx_header(rewind_core_t* core,
                          uint32_t talkgroup,
                          int32_t is_private,
                          uint8_t* out,
                          int32_t cap);

/// 再发一次刚才那个语音头，**沿用同一个序号**。
///
/// 规范原文：`Both messages may be sent several times (2-3 times with the same
/// sequence number) to ensure successful delivery.` 服务器按序号去重，
/// 所以重复帧必须复用上一个序号，否则会被当成三次不同的呼叫开始。
/// 没发过语音头时（序号还是 0）退化成一次正常的 `rw_core_tx_header`。
int32_t rw_core_tx_header_again(rewind_core_t* core,
                                uint32_t talkgroup,
                                int32_t is_private,
                                uint8_t* out,
                                int32_t cap);

/// 一个语音帧：27 字节三帧 AMBE（mode 33），正好是一个 DMR 突发的三帧。
int32_t rw_core_tx_audio(rewind_core_t* core,
                         const uint8_t* codec27,
                         uint8_t* out,
                         int32_t cap);

/// 结束符：DMR_DATA_BASE+2，无内容。
int32_t rw_core_tx_end(rewind_core_t* core, uint8_t* out, int32_t cap);

/// 这次发射已经发了多少个语音帧（用来决定什么时候插 KEEP_ALIVE）。
int32_t rw_core_tx_count(rewind_core_t* core);

#ifdef __cplusplus
}
#endif

#endif // REWIND_CORE_H
