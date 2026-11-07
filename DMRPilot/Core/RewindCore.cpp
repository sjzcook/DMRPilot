//
//  RewindCore.cpp
//  DMRPilot
//
//  BrandMeister Open DMR Terminal Protocol（Rewind）核心实现。
//  协议来源：BrandMeister Wiki / DigestPlay（ODMRTP 分支）的 Rewind.h 与 RewindClient.c。
//  与 Homebrew 那套最大的区别：订阅是显式命令，语音帧直接就是 27 字节 AMBE，
//  不需要 RS / BPTC / 交织 / 同步字 —— 那些只在 Homebrew 的 DMRD 载荷里才有。
//
//  许可证：协议头定义与登录流程参考 DigestPlay（BrandMeister，GPL-3.0-or-later）。
//

#include "RewindCore.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "SHA256.h"

// MARK: - 常量

static const int32_t RW_HEADER_BYTES = 18;   ///< 8 签名 + 2 类型 + 2 标志 + 4 序号 + 2 长度
static const char    RW_SIGN[]       = "REWIND01";

// 包类型（Rewind）
#define RW_TYPE_KEEP_ALIVE        0x0000
#define RW_TYPE_CLOSE             0x0001
#define RW_TYPE_CHALLENGE         0x0002
#define RW_TYPE_AUTHENTICATION    0x0003
#define RW_TYPE_REDIRECTION       0x0008
#define RW_TYPE_REPORT            0x0100
#define RW_TYPE_SUBSCRIPTION      0x0901
#define RW_TYPE_CANCELLING        0x0902
#define RW_TYPE_DMR_DATA_BASE     0x0910
#define RW_TYPE_DMR_AUDIO_FRAME   0x0920
#define RW_TYPE_DMR_EMBEDDED      (RW_TYPE_DMR_DATA_BASE + 0x17)
#define RW_TYPE_FAILURE_CODE      (RW_TYPE_DMR_DATA_BASE + 0x19)

// 标志
#define RW_FLAG_NONE       0x0000
#define RW_FLAG_REAL_TIME  0x0001   ///< 实时数据必须带，且用独立的序号计数器

// 服务类型：Open Terminal = 角色 APPLICATION(0x20) + 1
#define RW_SERVICE_OPEN_TERMINAL 0x21

// 订阅的会话类型：组呼 7 / 单呼 5
#define RW_SESSION_GROUP_VOICE   7
#define RW_SESSION_PRIVATE_VOICE 5

// MARK: - 状态

struct rewind_core {
    uint32_t dmr_id;
    char     password[64];
    char     version[64];
    int32_t  status;

    /// 两个序号计数器：0 = 常规包，1 = 实时包（语音）。
    /// 规范要求实时数据走独立的计数器。
    uint32_t counter[2];

    /// 当前会话的源 / 目的地址。语音帧本身不带地址，只能用最近一个语音头补上。
    uint32_t stream_src;
    uint32_t stream_dst;
    int32_t  stream_private;

    /// 本次发射已经发了多少个语音帧（用于每 5 秒插一次 KEEP_ALIVE）。
    int32_t  tx_count;

    /// 已经回过几次 AUTHENTICATION。服务器连续发挑战盐说明摘要它不认（密码错），
    /// 参考实现 RewindClient 的上限也是 3 次（ATTEMPT_COUNT）。
    int32_t  auth_attempt;

    int32_t  subscribed;
};

// MARK: - 小工具

static void write_le16(uint8_t* p, uint16_t v) {
    p[0] = uint8_t(v & 0xFFU);
    p[1] = uint8_t((v >> 8) & 0xFFU);
}

static void write_le32(uint8_t* p, uint32_t v) {
    p[0] = uint8_t(v & 0xFFU);
    p[1] = uint8_t((v >> 8) & 0xFFU);
    p[2] = uint8_t((v >> 16) & 0xFFU);
    p[3] = uint8_t((v >> 24) & 0xFFU);
}

static uint16_t read_le16(const uint8_t* p) {
    return uint16_t(uint16_t(p[0]) | (uint16_t(p[1]) << 8));
}

static uint32_t read_le32(const uint8_t* p) {
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
}

static void copy_text(char* dst, size_t cap, const char* src) {
    if (dst == NULL || cap == 0) {
        return;
    }
    if (src == NULL) {
        dst[0] = '\0';
        return;
    }
    size_t n = std::strlen(src);
    if (n > cap - 1U) {
        n = cap - 1U;
    }
    std::memcpy(dst, src, n);
    dst[n] = '\0';
}

/// 拼一个完整的 Rewind 包。返回总字节数，失败返回 0。
static int32_t build_frame(rewind_core* c, uint8_t* out, int32_t cap,
                           uint16_t type, uint16_t flags,
                           const uint8_t* data, int32_t dlen) {
    if (c == NULL || out == NULL || dlen < 0) {
        return 0;
    }
    int32_t total = RW_HEADER_BYTES + dlen;
    if (cap < total) {
        return 0;
    }

    std::memcpy(out, RW_SIGN, 8);
    write_le16(out + 8, type);
    write_le16(out + 10, flags);

    const int32_t index = (flags & RW_FLAG_REAL_TIME) ? 1 : 0;
    write_le32(out + 12, c->counter[index]);
    c->counter[index] = c->counter[index] + 1U;

    write_le16(out + 16, uint16_t(dlen));
    if (dlen > 0 && data != NULL) {
        std::memcpy(out + RW_HEADER_BYTES, data, size_t(dlen));
    }
    return total;
}

// MARK: - 生命周期

rewind_core* rw_core_create(void) {
    rewind_core* c = static_cast<rewind_core*>(std::calloc(1, sizeof(rewind_core)));
    if (c == NULL) {
        return NULL;
    }
    c->status = RW_STATUS_DISCONNECTED;
    copy_text(c->version, sizeof(c->version), "DMRPilot 1.0");
    return c;
}

void rw_core_destroy(rewind_core* c) {
    if (c != NULL) {
        std::free(c);
    }
}

void rw_core_set_identity(rewind_core* c, uint32_t dmr_id, const char* password) {
    if (c == NULL) {
        return;
    }
    // ODTP 用的是**7 位 DMR ID**，和 Homebrew 的 9 位热点 ID 不是一回事：
    // VersionData.number 里必须不带两位热点后缀，服务端拿它去匹配 SelfCare 密码。
    c->dmr_id = dmr_id & 0xFFFFFFU;
    copy_text(c->password, sizeof(c->password), password);
}

void rw_core_set_version(rewind_core* c, const char* version) {
    if (c == NULL) {
        return;
    }
    copy_text(c->version, sizeof(c->version), version);
}

void rw_core_reset(rewind_core* c) {
    if (c == NULL) {
        return;
    }
    c->status = RW_STATUS_DISCONNECTED;
    c->counter[0] = 0;
    c->counter[1] = 0;
    c->stream_src = 0;
    c->stream_dst = 0;
    c->stream_private = 0;
    c->tx_count = 0;
    c->auth_attempt = 0;
    c->subscribed = 0;
}

int32_t rw_core_status(rewind_core* c) {
    return c == NULL ? RW_STATUS_DISCONNECTED : c->status;
}

// MARK: - 建链

int32_t rw_core_keepalive(rewind_core* c, uint8_t* out, int32_t cap) {
    if (c == NULL) {
        return 0;
    }

    // RewindVersionData（小端）：number(4) + service(1) + description[变长]
    uint8_t data[80];
    std::memset(data, 0, sizeof(data));

    write_le32(data, c->dmr_id);
    data[4] = RW_SERVICE_OPEN_TERMINAL;

    size_t vlen = std::strlen(c->version);
    if (vlen > sizeof(data) - 6U) {
        vlen = sizeof(data) - 6U;
    }
    std::memcpy(data + 5, c->version, vlen);

    const int32_t dlen = int32_t(5U + vlen);
    const int32_t n = build_frame(c, out, cap, RW_TYPE_KEEP_ALIVE, RW_FLAG_NONE, data, dlen);

    // 第一次 KEEP_ALIVE 就是登录请求。之后每次调用只是心跳，不改状态。
    if (n > 0 && c->status == RW_STATUS_DISCONNECTED) {
        c->status = RW_STATUS_CONNECTING;
    }
    return n;
}

int32_t rw_core_subscribe(rewind_core* c, uint32_t talkgroup, uint8_t* out, int32_t cap) {
    if (c == NULL) {
        return 0;
    }

    // RewindSubscriptionData：type(4) + number(4)，都是小端
    uint8_t data[8];
    write_le32(data, RW_SESSION_GROUP_VOICE);
    write_le32(data + 4, talkgroup & 0xFFFFFFU);

    const int32_t n = build_frame(c, out, cap, RW_TYPE_SUBSCRIPTION, RW_FLAG_NONE, data, 8);
    if (n > 0) {
        c->status = RW_STATUS_SUBSCRIBING;
    }
    return n;
}

int32_t rw_core_cancel(rewind_core* c, uint8_t* out, int32_t cap) {
    if (c == NULL) {
        return 0;
    }
    return build_frame(c, out, cap, RW_TYPE_CANCELLING, RW_FLAG_NONE, NULL, 0);
}

int32_t rw_core_close(rewind_core* c, uint8_t* out, int32_t cap) {
    if (c == NULL) {
        return 0;
    }
    const int32_t n = build_frame(c, out, cap, RW_TYPE_CLOSE, RW_FLAG_NONE, NULL, 0);
    c->status = RW_STATUS_DISCONNECTED;
    return n;
}

// MARK: - 收包

int32_t rw_core_receive(rewind_core* c, const uint8_t* in, int32_t len, rw_result_t* r) {
    if (c == NULL || r == NULL) {
        return RW_EVT_NONE;
    }

    std::memset(r, 0, sizeof(*r));
    r->event = RW_EVT_NONE;
    r->status = c->status;

    if (in == NULL || len < RW_HEADER_BYTES) {
        return RW_EVT_NONE;
    }
    if (std::memcmp(in, RW_SIGN, 8) != 0) {
        return RW_EVT_NONE;
    }

    const uint16_t type = read_le16(in + 8);
    const uint32_t number = read_le32(in + 12);
    uint16_t dlen = read_le16(in + 16);

    int32_t avail = len - RW_HEADER_BYTES;
    if (avail < 0) {
        avail = 0;
    }
    if (int32_t(dlen) > avail) {
        dlen = uint16_t(avail);
    }

    const uint8_t* data = in + RW_HEADER_BYTES;
    r->number = number;

    switch (type) {
        case RW_TYPE_CHALLENGE: {
            // 挑战盐后面直接拼密码做 SHA256(盐 ‖ 密码)，和 Homebrew 的 RPTK 是同一套做法，
            // 区别只在 Homebrew 是「4 字节盐」，这里盐长度由服务器给（通常 32 字节）。
            if (c->status == RW_STATUS_CONNECTED) {
                break;
            }
            if (c->auth_attempt >= 3) {
                // 服务器第三次发挑战盐：它一直不认我们回的摘要（多半是密码不对，
                // 或者这个 7 位 ID 与密码根本不属于同一台设备）。再算下去只是空转。
                r->event = RW_EVT_AUTH_REJECTED;
                break;
            }

            uint8_t buffer[192];
            int32_t salt_len = int32_t(dlen);
            if (salt_len > 128) {
                salt_len = 128;
            }
            std::memcpy(buffer, data, size_t(salt_len));

            size_t plen = std::strlen(c->password);
            if (plen > sizeof(buffer) - size_t(salt_len) - 1U) {
                plen = sizeof(buffer) - size_t(salt_len) - 1U;
            }
            std::memcpy(buffer + salt_len, c->password, plen);

            uint8_t digest[32];
            CSHA256 sha;
            sha.buffer(buffer, uint32_t(salt_len) + uint32_t(plen), digest);

            // ★ 必须带 Rewind 头再发。服务器只认 `REWIND01` 开头的包，
            //   早先这里只把 32 字节摘要丢进 out，Swift 原样发出去 —— 服务器压根没看见，
            //   症状就是界面永远停在「鉴权中」。
            r->out_len = build_frame(c, r->out, int32_t(sizeof(r->out)),
                                     RW_TYPE_AUTHENTICATION, RW_FLAG_NONE, digest, 32);

            c->status = RW_STATUS_AUTH;
            c->auth_attempt = c->auth_attempt + 1;
            r->event = r->out_len > 0 ? RW_EVT_AUTH : RW_EVT_NONE;
            break;
        }

        case RW_TYPE_KEEP_ALIVE: {
            // 参考实现 RewindClient.c 的登录循环里**不看 payload 长度**：
            // 只要收到 KEEP_ALIVE 就认为鉴权通过、直接发订阅。
            // 早先这里写的是「dlen > 0 就当心跳」，于是某些 master 带上 VersionData
            // 回确认时，我们永远等不到 AUTHENTICATED，同样卡在「鉴权中」。
            if (c->status == RW_STATUS_AUTH) {
                c->status = RW_STATUS_SUBSCRIBING;
                r->event = RW_EVT_AUTHENTICATED;
            } else {
                r->event = RW_EVT_PONG;
            }
            break;
        }

        case RW_TYPE_REDIRECTION: {
            // 服务器让你换一台 master：family(2) + port(2) + address。
            // 这里不自动跟随（要重建 socket），但必须让它出现在日志里 ——
            // 否则用户只会看到「连不上」，而这其实是服务器明确指了另一台。
            int32_t n = 0;
            if (dlen >= 8) {
                const uint16_t family = read_le16(data);
                const uint16_t port = read_le16(data + 2);
                if (family == 2U) {
                    n = std::snprintf(reinterpret_cast<char*>(r->payload), sizeof(r->payload),
                                      "%u.%u.%u.%u:%u", unsigned(data[4]), unsigned(data[5]),
                                      unsigned(data[6]), unsigned(data[7]), unsigned(port));
                } else {
                    n = std::snprintf(reinterpret_cast<char*>(r->payload), sizeof(r->payload),
                                      "family %u port %u", unsigned(family), unsigned(port));
                }
            } else {
                n = std::snprintf(reinterpret_cast<char*>(r->payload), sizeof(r->payload), "地址未知");
            }
            r->out_len = n > 0 ? n : 0;
            r->event = RW_EVT_REDIRECT;
            break;
        }

        case RW_TYPE_SUBSCRIPTION: {
            // 服务器确认订阅（同样类型、无内容）。
            c->status = RW_STATUS_CONNECTED;
            c->subscribed = 1;
            r->event = RW_EVT_SUBSCRIBED;
            break;
        }

        case (RW_TYPE_DMR_DATA_BASE + 1): {
            // 12 字节 Full LC：flco(1) fid(1) 服务选项(1) 目的(3) 源(3) CRC(3)
            if (dlen < 9) {
                break;
            }
            const uint8_t flco = uint8_t(data[0] & 0x3FU);
            r->dst = (uint32_t(data[3]) << 16) | (uint32_t(data[4]) << 8) | uint32_t(data[5]);
            r->src = (uint32_t(data[6]) << 16) | (uint32_t(data[7]) << 8) | uint32_t(data[8]);
            // FLCO 3 = 单呼，0 = 组呼
            r->is_private = (flco == 3U) ? 1 : 0;

            c->stream_src = r->src;
            c->stream_dst = r->dst;
            c->stream_private = r->is_private;

            r->event = RW_EVT_RX_HEADER;
            break;
        }

        case (RW_TYPE_DMR_DATA_BASE + 2): {
            r->src = c->stream_src;
            r->dst = c->stream_dst;
            r->is_private = c->stream_private;
            r->event = RW_EVT_RX_EOT;
            break;
        }

        case RW_TYPE_DMR_AUDIO_FRAME: {
            // 27 字节 = 3 × 9 字节 AMBE mode 33，正好是解码器要的格式，不用再拆。
            if (dlen < 27) {
                break;
            }
            std::memcpy(r->codec, data, 27);
            r->src = c->stream_src;
            r->dst = c->stream_dst;
            r->is_private = c->stream_private;
            r->event = RW_EVT_RX_VOICE;
            break;
        }

        case RW_TYPE_REPORT: {
            int32_t n = int32_t(dlen);
            if (n > int32_t(sizeof(r->payload) - 1U)) {
                n = int32_t(sizeof(r->payload) - 1U);
            }
            if (n > 0) {
                std::memcpy(r->payload, data, size_t(n));
            }
            r->out_len = n;
            r->event = RW_EVT_REPORT;
            break;
        }

        case RW_TYPE_FAILURE_CODE: {
            // 订阅被拒 / 会话不被允许时服务器回这个。R3ABM 的头文件里没有它的结构体，
            // 实测前两个字节是小端的失败码，其余留给文本。原样带上去给上层显示。
            int32_t n = int32_t(dlen);
            if (n > int32_t(sizeof(r->payload) - 1U)) {
                n = int32_t(sizeof(r->payload) - 1U);
            }
            if (n > 0) {
                std::memcpy(r->payload, data, size_t(n));
            }
            r->out_len = n;
            r->event = RW_EVT_FAILURE;
            break;
        }

        case RW_TYPE_CLOSE: {
            c->status = RW_STATUS_DISCONNECTED;
            r->event = RW_EVT_CLOSED;
            break;
        }

        default:
            break;
    }

    r->status = c->status;
    return r->event;
}

// MARK: - 发射

/// 拼 12 字节 Full LC。
///   byte0: flco(6) | reserved(1) | protect(1)
///   byte1: FID   byte2: 服务选项
///   byte3..5: 目的地址（3 字节大端）  byte6..8: 源地址（3 字节大端）
///   byte9..11: CRC —— 规范允许跳过计算，DigestPlay 也全填 0
static void build_lc(const rewind_core* c, uint32_t talkgroup, int32_t is_private, uint8_t* lc) {
    std::memset(lc, 0, 12);
    lc[0] = is_private ? 0x03U : 0x00U;
    lc[1] = 0x00U;
    lc[2] = 0x00U;
    lc[3] = uint8_t((talkgroup >> 16) & 0xFFU);
    lc[4] = uint8_t((talkgroup >> 8) & 0xFFU);
    lc[5] = uint8_t(talkgroup & 0xFFU);
    lc[6] = uint8_t((c->dmr_id >> 16) & 0xFFU);
    lc[7] = uint8_t((c->dmr_id >> 8) & 0xFFU);
    lc[8] = uint8_t(c->dmr_id & 0xFFU);
}

int32_t rw_core_tx_header(rewind_core* c, uint32_t talkgroup, int32_t is_private,
                          uint8_t* out, int32_t cap) {
    if (c == NULL) {
        return 0;
    }

    uint8_t lc[12];
    build_lc(c, talkgroup, is_private, lc);

    c->tx_count = 0;
    return build_frame(c, out, cap, uint16_t(RW_TYPE_DMR_DATA_BASE + 1), RW_FLAG_REAL_TIME, lc, 12);
}

int32_t rw_core_tx_header_again(rewind_core* c, uint32_t talkgroup, int32_t is_private,
                                uint8_t* out, int32_t cap) {
    if (c == NULL) {
        return 0;
    }

    // 还没发过实时包：没有「上一个序号」可复用，当成第一次发。
    if (c->counter[1] == 0U) {
        return rw_core_tx_header(c, talkgroup, is_private, out, cap);
    }

    uint8_t lc[12];
    build_lc(c, talkgroup, is_private, lc);

    // 把计数器退回一格：build_frame 读出 saved-1（= 上一次用的号）后再 ++ 回 saved，
    // 这样重复帧的序号和上一帧完全相同，服务器按序号去重。
    const uint32_t saved = c->counter[1];
    c->counter[1] = saved - 1U;
    int32_t n = build_frame(c, out, cap, uint16_t(RW_TYPE_DMR_DATA_BASE + 1), RW_FLAG_REAL_TIME, lc, 12);
    c->counter[1] = saved;  // build_frame 成功时已经是 saved；失败时补回来，别把序号丢了
    return n;
}

int32_t rw_core_tx_audio(rewind_core* c, const uint8_t* codec27, uint8_t* out, int32_t cap) {
    if (c == NULL || codec27 == NULL) {
        return 0;
    }
    const int32_t n = build_frame(c, out, cap, RW_TYPE_DMR_AUDIO_FRAME, RW_FLAG_REAL_TIME, codec27, 27);
    if (n > 0) {
        c->tx_count += 1;
    }
    return n;
}

int32_t rw_core_tx_end(rewind_core* c, uint8_t* out, int32_t cap) {
    if (c == NULL) {
        return 0;
    }
    const int32_t n = build_frame(c, out, cap, uint16_t(RW_TYPE_DMR_DATA_BASE + 2), RW_FLAG_REAL_TIME, NULL, 0);
    c->tx_count = 0;
    return n;
}

int32_t rw_core_tx_count(rewind_core* c) {
    return c == NULL ? 0 : c->tx_count;
}
