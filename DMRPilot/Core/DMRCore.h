//
//  DMRCore.h
//  DMRPilot
//
//  Homebrew / MMDVM 协议核心：握手、收帧、组帧全部在 C++ 里完成。
//
//  这一层是 DroidStar 的 DMR 类（dmr.cpp，GPL-3.0-or-later）去掉 Qt 之后的直译：
//  同样的状态机、同样的帧布局、同样的编码链（RS(12,9) → BPTC(196,96) → Golay(20,8)），
//  连函数名都尽量保持一致，方便逐行对照。
//
//  为什么用 C++ 而不是 Swift：这些比特级编码以前用 Swift 重写过三遍，
//  RS 反馈抽头、同步字、载荷偏移各错过一次，每次都表现为「能连上但收不到」。
//  参考实现的算法源码本身没有 Qt 依赖，直接搬过来用比再抄一遍可靠得多。
//
//  边界：
//
//      Swift  ──  UDP / WebSocket、定时器、音频、界面
//        │
//        ▼
//     DMRCore ── 只负责「字节」：这包该回什么、这帧该长什么样、这包解出谁的语音
//
//  这里没有任何网络、线程、内存分配（除了 create/destroy），
//  所有缓冲都由调用方传进来，所以 Swift 侧可以放心地在主线程上直接调用。
//

#ifndef DMR_CORE_H
#define DMR_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 不透明句柄：内部是 DMR 的状态（成员、缓冲、时隙、色码……）。
typedef struct dmr_core dmr_core_t;

// 会话状态，与 DroidStar 的 `m_modeinfo.status` 一一对应。
//
// 用 #define 而不是 enum：Swift 把带名字的 C enum 导入成 RawRepresentable 结构体，
// 和 int32_t 字段比较会编译不过；宏导出的就是 Int32 常量，省掉一层转换。
#define DMR_STATUS_DISCONNECTED 0
#define DMR_STATUS_CONNECTING   1   // 已发 RPTL，等挑战盐
#define DMR_STATUS_AUTH         2   // 已发 RPTK，等鉴权结果
#define DMR_STATUS_CONF         3   // 已发 RPTC，等最后一个 RPTACK
#define DMR_STATUS_CONNECTED    4   // CONNECTED_RW，可以收发语音

// 收到一个数据包之后，调用方要做什么。
#define DMR_EVT_NONE      0
#define DMR_EVT_AUTH      1   // 回发 result->out（40 字节 RPTK）
#define DMR_EVT_CONFIG    2   // 回发 result->out（302 字节 RPTC）
#define DMR_EVT_CONNECTED 3   // 三段握手走完，进入收发状态
#define DMR_EVT_NAK       4   // MSTNAK：会话被拒 / 被清
#define DMR_EVT_CLOSED    5   // MSTCL：master 关闭会话
#define DMR_EVT_PONG      6   // MSTPONG：心跳应答
#define DMR_EVT_RX_HEADER 7   // 语音头（带 LC 的那种控制帧）
#define DMR_EVT_RX_EOT    8   // 语音结束符
#define DMR_EVT_RX_VOICE  9   // 语音突发（result->codec 里是 27 字节 AMBE）
#define DMR_EVT_RX_OTHER  10  // 其它带 0x20 的控制帧（CSBK / 数据头等）

/// 一次收包的结果。所有字段总是被写满，调用方不必预先清零。
typedef struct {
    int32_t  event;          ///< dmr_event_t
    int32_t  status;         ///< 处理完这个包之后的会话状态
    uint32_t src;            ///< 3 字节源地址（7 位 DMR ID）
    uint32_t dst;            ///< 3 字节目的地址（通话组或对方 ID）
    uint32_t peer;           ///< 4 字节 gwid（热点自己的 9 位 ID）
    uint32_t stream_id;      ///< 4 字节流号
    int32_t  seq;            ///< 帧序号（DMRD 第 4 字节）
    int32_t  slot;           ///< 1 / 2
    int32_t  is_private;     ///< 1 = 单呼
    int32_t  data_type;      ///< 控制帧的数据类型（1 语音头 / 2 结束符）
    int32_t  burst;          ///< 语音突发的超帧序号 0…5
    int32_t  out_len;        ///< out 里有效的字节数
    uint8_t  payload[33];    ///< 33 字节语音载荷（原样）
    uint8_t  codec[27];      ///< 语音突发拆出来的 3 个 AMBE 帧
    uint8_t  out[302];       ///< 需要回发的帧（RPTK / RPTC）
} dmr_result_t;

/// 连接参数里的数值部分。字符串另用 `dmr_core_set_text` 单独设置——
/// 结构体里塞 `const char*` 的话，Swift 侧要嵌套六层 `withCString` 才能传进来。
typedef struct {
    uint32_t essid;          ///< 9 位热点 ID：RPTL / RPTK / RPTC / DMRD 的 peer 都用它
    uint32_t dmr_id;         ///< 7 位个人 DMR ID：DMRD 的 src 只有 3 字节，不能用 9 位
    uint32_t frequency;      ///< 频率（Hz），只写进 RPTC，不参与通信；0 = 438.8 MHz
    uint8_t  color_code;     ///< 色码 0…15，只影响发出去的语音载荷
    int32_t  send_config;    ///< 1 = 走完整三段握手（发 RPTC），0 = 两段就上线
} dmr_setup_t;

// dmr_core_set_text 的字段号。
#define DMR_TEXT_PASSWORD    0   // ≤ 63 字节
#define DMR_TEXT_CALLSIGN    1   // ≤ 8 字节，RPTC 前 8 字节
#define DMR_TEXT_LOCATION    2   // ≤ 20 字节
#define DMR_TEXT_DESCRIPTION 3   // ≤ 19 字节
#define DMR_TEXT_URL         4   // ≤ 124 字节
#define DMR_TEXT_SOFTWARE    5   // ≤ 40 字节
#define DMR_TEXT_PACKAGE     6   // ≤ 40 字节

// MARK: - 生命周期

dmr_core_t* dmr_core_create(void);
void        dmr_core_destroy(dmr_core_t* core);

/// 设置数值参数。可以随时调用，下一次建链时生效。
void dmr_core_set_params(dmr_core_t* core, const dmr_setup_t* setup);

/// 设置字符串参数（密码 / 呼号 / 位置等）。`value` 为 NULL 等于清空。
void dmr_core_set_text(dmr_core_t* core, int32_t field, const char* value);

/// DMRD 里的目的地址。点「确定」切组时调用，下一次发射就发给这个组。
void dmr_core_set_talkgroup(dmr_core_t* core, uint32_t talkgroup);
uint32_t dmr_core_talkgroup(dmr_core_t* core);
void dmr_core_set_color_code(dmr_core_t* core, uint8_t color_code);

/// 当前会话状态（dmr_status_t）。
int32_t dmr_core_status(dmr_core_t* core);

/// 把状态机退回「未连接」，但保留参数。重连前调用。
void dmr_core_reset(dmr_core_t* core);

// MARK: - 建链

/// 生成 RPTL（8 字节）。调用前状态应已 reset。
int32_t dmr_core_login(dmr_core_t* core, uint8_t* out, int32_t cap);

/// 生成 RPTPING（11 字节）。在线后每 5 秒一次。
int32_t dmr_core_ping(dmr_core_t* core, uint8_t* out, int32_t cap);

/// 生成 RPTCL（9 字节）。主动登出，不发的话重连会被判「ID 已被占用」。
int32_t dmr_core_logout(dmr_core_t* core, uint8_t* out, int32_t cap);

// MARK: - 收包

/// 处理一个收到数据包。返回值是 result->event。
int32_t dmr_core_receive(dmr_core_t* core,
                         const uint8_t* in,
                         int32_t len,
                         dmr_result_t* result);

// MARK: - 发射

/// 开始一次发射：固定目的地址 / 时隙 / 色码，生成语音头（55 字节）。
///
/// `is_private` 非 0 时按单呼组帧：LC 的 FLCO 填 3（`FLCO_USER_USER`），
/// 包头 byte15 的 bit6 拉高。组呼填 0，其余字节完全一样——
/// 语音突发的编码链两者不区分，所以只在语音头这里分一次就够了。
int32_t dmr_core_tx_begin(dmr_core_t* core,
                          uint32_t destination,
                          uint8_t slot,
                          uint8_t color_code,
                          uint8_t is_private,
                          uint8_t* out,
                          int32_t cap);

/// 一个语音突发：把 27 字节 AMBE 装进超帧的下一个位置。
/// 同步字 / 嵌入 LC / DMREMB 全部由这里按 `(dmrcnt-1) % 6` 算，调用方不用管。
int32_t dmr_core_tx_burst(dmr_core_t* core,
                          const uint8_t* codec27,
                          uint8_t* out,
                          int32_t cap);

/// 结束发射：带 LC 的结束符（55 字节）。
int32_t dmr_core_tx_end(dmr_core_t* core, uint8_t* out, int32_t cap);

/// 这次发射是否还活着（语音头已发、结束符未发）。
int32_t dmr_core_tx_active(dmr_core_t* core);

/// 这次发射已经发了多少帧（语音头算 1）。
int32_t dmr_core_tx_count(dmr_core_t* core);

/// MMDVM 的 27 字节静音 AMBE（`DMR_SILENCE_DATA`）。
/// 「订阅通话组」就是用它跑一次完整的 PTT：语音头 + 若干突发 + 结束符。
void dmr_core_silence_codec(uint8_t* out27);

#ifdef __cplusplus
}
#endif

#endif // DMR_CORE_H
