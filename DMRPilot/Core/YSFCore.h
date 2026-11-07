//
//  YSFCore.h
//  DMRPilot
//
//  YSF（System Fusion / C4FM）反射器协议核心：登录、收帧、组帧全部在 C++ 里完成。
//
//  这一层是 DroidStar 的 YSF 类（ysf.cpp，GPL-3.0-or-later）去掉 Qt 之后的直译：
//  同样的状态机、同样的 155 字节包布局、同样的编码链
//  （CCITT-16 → 卷积码(2,1,5) → Golay(24,12) → 交织）。函数名尽量保持原样，
//  方便逐行对照 —— 和 DMRCore / RewindCore 是同一套做法。
//
//  ── 和 DMR 那条链路的区别 ────────────────────────────────────────────
//
//  1. 身份是**呼号**（≤10 ASCII），不是数字 ID；登录就是一句 "YSFP" + 呼号。
//  2. 没有鉴权、没有配置包、没有订阅：连通即收发，心跳也是同一个 "YSFP" 包。
//  3. 一包 155 字节 = 4 字节 "YSFD" + 10 网关 + 10 源 + 10 目的 + 1 计数
//     + 120 字节空口数据（5 同步 + 25 FICH + 90 语音/信令）。
//  4. 语音是 **5 个 20 ms 帧**打成一包（100 ms），每帧 49 bit 的 AMBE+2 2450，
//     所以包率是 10 包/秒 —— DMR 那边是 60 ms 一个突发、3 帧。
//  5. FICH 里带帧号/帧总数/数据类型，收流靠它判断「开头 / 说话中 / 结束」。
//
//  ── 边界 ─────────────────────────────────────────────────────────────
//
//      Swift ── UDP、定时器、音频、界面
//        │
//        ▼
//    YSFCore ── 只负责「字节」：这包什么意思、这帧该长什么样
//
//  FCS（"FCS" 开头的那种反射器）用的是另一套封装（130 字节 + PING/CLOSE），
//  这里不实现 —— 见 `ysf_core_receive` 开头的说明。
//

#ifndef YSF_CORE_H
#define YSF_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 不透明句柄：内部是呼号、目的地址、状态机与发射计数。
typedef struct ysf_core ysf_core_t;

// 会话状态。用 #define 而不是 enum：Swift 把带名字的 C enum 导入成 RawRepresentable，
// 和 int32_t 字段比较会编译不过（DMRCore 那边踩过）。
#define YSF_STATUS_DISCONNECTED 0
#define YSF_STATUS_CONNECTING   1   // 已发 YSFP，等服务器的 14 字节回应
#define YSF_STATUS_ONLINE       2   // 连通，可以收发

// 收到一个数据包之后，调用方要做什么。
#define YSF_EVT_NONE      0
#define YSF_EVT_CONNECTED 1   // 收到 14 字节回应：可以开始收发了
#define YSF_EVT_PONG      2   // 收到 "ONLINE"：心跳活着
#define YSF_EVT_RX_HEADER 3   // 语音头（FI=0）：src / dst 已解出来
#define YSF_EVT_RX_VOICE  4   // 语音包：result->codec 里是 5 个 7 字节 AMBE 帧
#define YSF_EVT_RX_END    5   // 语音结束符（FI=2）
#define YSF_EVT_RX_OTHER  6   // 其它（数据帧 / 全速率语音）：只做日志

/// 一包 5 帧语音：5 × 7 = 35 字节
#define YSF_CODEC_BYTES   35
/// 一包里的语音帧数
#define YSF_CODEC_FRAMES  5
/// 呼号字段宽度（不足补空格，不是 0 结尾）
#define YSF_CALLSIGN_BYTES 10
/// 完整包长度（YSF 反射器）
#define YSF_PACKET_BYTES  155

/// 一次收包的结果。所有字段总是被写满。
typedef struct {
    int32_t event;          ///< YSF_EVT_*
    int32_t status;         ///< 处理完这个包之后的会话状态
    int32_t fi;             ///< FICH 的帧类型：0 头 / 1 说话中 / 2 结束 / 3 测试
    int32_t dt;             ///< FICH 的数据类型：0 VD1 / 1 数据 / 2 VD2 / 3 全速率语音
    int32_t fn;             ///< 帧号 0…6（一个超帧 7 帧）
    int32_t ft;             ///< 帧总数（一般是 6）
    int32_t frame_counter;  ///< 包第 34 字节的高 7 位，服务器用它排流
    int32_t voip;           ///< FICH 的 VoIP 标志
    int32_t codec_len;      ///< codec 里有效的字节数（语音包是 35）
    uint8_t codec[35];      ///< 5 × 7 字节 AMBE（2450 bps，未加 FEC）
    uint8_t src[11];        ///< 源呼号，空格补齐 + 结尾 0
    uint8_t dst[11];        ///< 目的呼号（组呼是 "ALL" 或组名）
    uint8_t gw[11];         ///< 网关 / 反射器侧的呼号
} ysf_result_t;

// MARK: - 生命周期

ysf_core_t* ysf_core_create(void);
void        ysf_core_destroy(ysf_core_t* core);

/// 自己的呼号（≤10 字节，ASCII）。写进每个发包的源字段与登录包。
void ysf_core_set_callsign(ysf_core_t* core, const char* callsign);

/// 目的呼号，默认 "ALL"（YSF 的组呼就是 ALL）。
void ysf_core_set_destination(ysf_core_t* core, const char* destination);

/// 当前会话状态（YSF_STATUS_*）。
int32_t ysf_core_status(ysf_core_t* core);

/// 退回「未连接」，保留呼号。重连前调用。
void ysf_core_reset(ysf_core_t* core);

// MARK: - 建链

/// 生成登录包（14 字节："YSFP" + 呼号补空格）。心跳用的是同一个包。
int32_t ysf_core_login(ysf_core_t* core, uint8_t* out, int32_t cap);
int32_t ysf_core_ping(ysf_core_t* core, uint8_t* out, int32_t cap);

/// 生成登出包（14 字节："YSFU" + 呼号）。不发的话反射器要等超时才放掉这个呼号。
int32_t ysf_core_logout(ysf_core_t* core, uint8_t* out, int32_t cap);

// MARK: - 收包

/// 处理一个收到数据包。返回值是 result->event。
int32_t ysf_core_receive(ysf_core_t* core,
                         const uint8_t* in,
                         int32_t len,
                         ysf_result_t* result);

// MARK: - 发射

/// 语音头（155 字节）。FI=0、FN=0、FT=6；DCH 里带 CSD1/CSD2 两组呼号。
int32_t ysf_core_tx_begin(ysf_core_t* core, uint8_t* out, int32_t cap);

/// 一包语音（155 字节）：`codec35` 是 5 个 7 字节 AMBE 帧，按 VD 模式 2 组帧。
int32_t ysf_core_tx_voice(ysf_core_t* core,
                          const uint8_t* codec35,
                          uint8_t* out,
                          int32_t cap);

/// 结束符（155 字节）：FI=2，第 34 字节最低位置 1。
int32_t ysf_core_tx_end(ysf_core_t* core, uint8_t* out, int32_t cap);

/// 这次发射已经发了多少个包（语音头算 1，结束符不算）。
int32_t ysf_core_tx_count(ysf_core_t* core);

#ifdef __cplusplus
}
#endif

#endif // YSF_CORE_H
