//
//  DMRCore.cpp
//  DMRPilot
//
//  DroidStar `dmr.cpp` 的 DMR 类去掉 Qt 之后的直译。
//
//  和原实现的对应关系（改代码时请对着 dmr.cpp 看，别凭想象改）：
//
//      DMR::hostname_lookup  → dmr_core_login        （发 RPTL）
//      DMR::process_udp      → dmr_core_receive      （三段握手 + 收 DMRD）
//      DMR::send_ping        → dmr_core_ping         （RPTPING）
//      DMR::send_disconnect  → dmr_core_logout       （RPTCL）
//      DMR::setup_connection → 状态切 CONNECTED
//      DMR::send_frame       → dmr_core_tx_begin / dmr_core_tx_burst / dmr_core_tx_end
//      DMR::build_frame      → build_frame
//      DMR::encode_header    → encode_header
//      DMR::encode_data      → encode_data
//      DMR::full_lc_encode   → full_lc_encode
//
//  下层的 RS(12,9)、BPTC(196,96)、Golay(20,8)、Hamming、CRC5、SHA256 都是
//  DroidStar / MMDVMHost 的原文件（同目录），一行没改 —— 这几个文件正是
//  以前用 Swift 重写时反复出错的地方（RS 抽头、同步字掩码、载荷偏移）。
//
//  许可证：以下代码与同目录的编码器源码同源，均为 GPL-3.0-or-later
//  （DroidStar: Copyright (C) 2019-2021 Doug McLain；
//    MMDVM 部分: Copyright (C) 2015-2018 Jonathan Naylor G4KLX）。
//

#include "DMRCore.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "CRCenc.h"
#include "DMRDefines.h"
#include "SHA256.h"
#include "cbptc19696.h"
#include "cgolay2087.h"
#include "chamming.h"
#include "crs129.h"

// MARK: - 常量

// QR(16,7) 编码表：嵌入信令 DMREMB 的 7 位信息 → 16 位系统码。
// 与 dmr.cpp 顶部的同名表逐项一致，128 项。
static const uint32_t ENCODING_TABLE_1676[] = {
    0x0000U, 0x0273U, 0x04E5U, 0x0696U, 0x09C9U, 0x0BBAU, 0x0D2CU, 0x0F5FU, 0x11E2U, 0x1391U, 0x1507U, 0x1774U,
    0x182BU, 0x1A58U, 0x1CCEU, 0x1EBDU, 0x21B7U, 0x23C4U, 0x2552U, 0x2721U, 0x287EU, 0x2A0DU, 0x2C9BU, 0x2EE8U,
    0x3055U, 0x3226U, 0x34B0U, 0x36C3U, 0x399CU, 0x3BEFU, 0x3D79U, 0x3F0AU, 0x411EU, 0x436DU, 0x45FBU, 0x4788U,
    0x48D7U, 0x4AA4U, 0x4C32U, 0x4E41U, 0x50FCU, 0x528FU, 0x5419U, 0x566AU, 0x5935U, 0x5B46U, 0x5DD0U, 0x5FA3U,
    0x60A9U, 0x62DAU, 0x644CU, 0x663FU, 0x6960U, 0x6B13U, 0x6D85U, 0x6FF6U, 0x714BU, 0x7338U, 0x75AEU, 0x77DDU,
    0x7882U, 0x7AF1U, 0x7C67U, 0x7E14U, 0x804FU, 0x823CU, 0x84AAU, 0x86D9U, 0x8986U, 0x8BF5U, 0x8D63U, 0x8F10U,
    0x91ADU, 0x93DEU, 0x9548U, 0x973BU, 0x9864U, 0x9A17U, 0x9C81U, 0x9EF2U, 0xA1F8U, 0xA38BU, 0xA51DU, 0xA76EU,
    0xA831U, 0xAA42U, 0xACD4U, 0xAEA7U, 0xB01AU, 0xB269U, 0xB4FFU, 0xB68CU, 0xB9D3U, 0xBBA0U, 0xBD36U, 0xBF45U,
    0xC151U, 0xC322U, 0xC5B4U, 0xC7C7U, 0xC898U, 0xCAEBU, 0xCC7DU, 0xCE0EU, 0xD0B3U, 0xD2C0U, 0xD456U, 0xD625U,
    0xD97AU, 0xDB09U, 0xDD9FU, 0xDFECU, 0xE0E6U, 0xE295U, 0xE403U, 0xE670U, 0xE92FU, 0xEB5CU, 0xEDCAU, 0xEFB9U,
    0xF104U, 0xF377U, 0xF5E1U, 0xF792U, 0xF8CDU, 0xFABEU, 0xFC28U, 0xFE5BU};

/// MMDVM 的 `DMR_SILENCE_DATA`：一个「什么都不说」的 AMBE 帧，9 字节重复 3 次。
/// 订阅通话组时用它凑满一个真实发射，对端听到的是静音而不是杂音。
static const uint8_t DMR_SILENCE_AMBE[9] = {0xB9U, 0xE8U, 0x81U, 0x52U, 0x61U, 0x73U, 0x00U, 0x2AU, 0x6BU};

/// 单帧长度：55 字节是 MMDVMHost 2024+ / BrandMeister 的现行格式
/// （streamId 4 字节 @16…19，载荷 33 字节 @20…52，BER/RSSI @53/54）。
static const int32_t DMR_FRAME_BYTES = 55;

/// 发射流号的自增部分（见 dmr_core_tx_begin）。
static uint32_t g_stream_seq = 0U;

// MARK: - 状态

struct dmr_core {
    // ---- 连接参数（dmr_setup_t）----
    uint32_t essid;         ///< 9 位热点 ID
    uint32_t dmr_id;        ///< 7 位个人 DMR ID
    uint32_t frequency;     ///< Hz，只用于 RPTC
    uint8_t color_code;     ///< 0…15
    bool send_config;       ///< 是否上报 RPTC
    char password[64];
    char callsign[16];
    char location[24];
    char description[24];
    char url[128];
    char software_id[48];
    char package_id[48];

    // ---- 会话 ----
    int32_t status;         ///< dmr_status_t
    int32_t pongs;          ///< 收到的 MSTPONG 数

    // ---- 发射状态（对应 DMR 的 m_tx* 成员）----
    uint32_t tx_src;        ///< m_txsrcid，7 位
    uint32_t tx_dst;        ///< m_txdstid，通话组
    uint32_t tx_stream;     ///< m_txstreamid
    uint8_t tx_slot;        ///< m_txslot，1 / 2
    uint8_t tx_cc;          ///< 发射用色码
    uint8_t flco;           ///< 0 = 组呼，3 = 单呼
    uint8_t data_type;      ///< m_dataType
    uint32_t dmr_cnt;       ///< m_dmrcnt，一次发射内的帧计数
    bool tx_active;
    uint8_t ambe[27];       ///< m_ambe
    uint8_t frame[55];      ///< m_dmrFrame
    bool raw[128];          ///< m_raw
    bool data[72];          ///< m_data
    CBPTC19696 bptc;        ///< m_bptc

    dmr_core()
        : essid(0), dmr_id(0), frequency(438800000U), color_code(1), send_config(true),
          status(DMR_STATUS_DISCONNECTED), pongs(0),
          tx_src(0), tx_dst(0), tx_stream(0), tx_slot(2), tx_cc(1),
          flco(0), data_type(0), dmr_cnt(0), tx_active(false) {
        std::memset(password, 0, sizeof(password));
        std::memset(callsign, 0, sizeof(callsign));
        std::memset(location, 0, sizeof(location));
        std::memset(description, 0, sizeof(description));
        std::memset(url, 0, sizeof(url));
        std::memset(software_id, 0, sizeof(software_id));
        std::memset(package_id, 0, sizeof(package_id));
        std::memset(ambe, 0, sizeof(ambe));
        std::memset(frame, 0, sizeof(frame));
        std::memset(raw, 0, sizeof(raw));
        std::memset(data, 0, sizeof(data));
    }
};

// MARK: - 工具

static void copy_text(char* dst, size_t cap, const char* src) {
    if (dst == NULL || cap == 0) {
        return;
    }
    if (src == NULL) {
        dst[0] = '\0';
        return;
    }
    size_t n = std::strlen(src);
    if (n >= cap) {
        n = cap - 1;
    }
    std::memcpy(dst, src, n);
    dst[n] = '\0';
}

static void byte_to_bits_be(uint8_t byte, bool* bits) {
    bits[0] = (byte & 0x80U) == 0x80U;
    bits[1] = (byte & 0x40U) == 0x40U;
    bits[2] = (byte & 0x20U) == 0x20U;
    bits[3] = (byte & 0x10U) == 0x10U;
    bits[4] = (byte & 0x08U) == 0x08U;
    bits[5] = (byte & 0x04U) == 0x04U;
    bits[6] = (byte & 0x02U) == 0x02U;
    bits[7] = (byte & 0x01U) == 0x01U;
}

static void bits_to_byte_be(const bool* bits, uint8_t& byte) {
    byte = bits[0] ? 0x80U : 0x00U;
    byte |= bits[1] ? 0x40U : 0x00U;
    byte |= bits[2] ? 0x20U : 0x00U;
    byte |= bits[3] ? 0x10U : 0x00U;
    byte |= bits[4] ? 0x08U : 0x00U;
    byte |= bits[5] ? 0x04U : 0x00U;
    byte |= bits[6] ? 0x02U : 0x00U;
    byte |= bits[7] ? 0x01U : 0x00U;
}

// MARK: - 前向声明

static void add_dmr_data_sync(uint8_t* data, bool duplex);
static void add_dmr_audio_sync(uint8_t* data, bool duplex);
static void get_slot_data(dmr_core* c, uint8_t* data);
static void lc_get_bytes(dmr_core* c, uint8_t* bytes);
static void lc_get_bits(dmr_core* c, bool* bits);
static void encode_embedded_data(dmr_core* c);
static uint8_t get_embedded_data(dmr_core* c, uint8_t* data, uint8_t n);
static void get_emb_data(dmr_core* c, uint8_t* data, uint8_t lcss);
static void encode_qr1676(uint8_t* data);
static void full_lc_encode(dmr_core* c, uint8_t* data, uint8_t type);
static void encode_header(dmr_core* c, uint8_t type);
static void encode_data(dmr_core* c);
static void build_frame(dmr_core* c);

// MARK: - LC（链路控制）字段

/// LC 的 9 个字节：FLCO / FID / 服务选项 / 目的地址 / 源地址。
///
/// 注意源地址用的是 **7 位 dmr_id**，不是 9 位 essid —— 3 字节字段放不下 9 位，
/// 溢出后会变成别人的 DMR ID，master 按 peer 校验身份时整帧丢弃。
static void lc_get_bytes(dmr_core* c, uint8_t* bytes) {
    std::memset(bytes, 0, 9);
    bytes[0] = c->flco;
    bytes[1] = 0;
    bytes[2] = 0;
    bytes[3] = uint8_t(c->tx_dst >> 16);
    bytes[4] = uint8_t(c->tx_dst >> 8);
    bytes[5] = uint8_t(c->tx_dst >> 0);
    bytes[6] = uint8_t(c->dmr_id >> 16);
    bytes[7] = uint8_t(c->dmr_id >> 8);
    bytes[8] = uint8_t(c->dmr_id >> 0);
}

static void lc_get_bits(dmr_core* c, bool* bits) {
    uint8_t bytes[9];
    lc_get_bytes(c, bytes);
    for (int i = 0; i < 9; ++i) {
        byte_to_bits_be(bytes[i], bits + i * 8);
    }
}

// MARK: - 嵌入信令（语音突发里的 LC 分片）

/// 9 字节 LC → 128 bit 嵌入信令块。分 4 段塞进超帧的第 1…4 个突发。
static void encode_embedded_data(dmr_core* c) {
    uint32_t crc = 0U;
    lc_get_bits(c, c->data);
    CCRC::encodeFiveBit(c->data, crc);

    bool data[128U];
    std::memset(data, 0x00U, 128U * sizeof(bool));

    data[106U] = (crc & 0x01U) == 0x01U;
    data[90U] = (crc & 0x02U) == 0x02U;
    data[74U] = (crc & 0x04U) == 0x04U;
    data[58U] = (crc & 0x08U) == 0x08U;
    data[42U] = (crc & 0x10U) == 0x10U;

    uint32_t b = 0U;
    for (uint32_t a = 0U; a < 11U; a++, b++)
        data[a] = c->data[b];
    for (uint32_t a = 16U; a < 27U; a++, b++)
        data[a] = c->data[b];
    for (uint32_t a = 32U; a < 42U; a++, b++)
        data[a] = c->data[b];
    for (uint32_t a = 48U; a < 58U; a++, b++)
        data[a] = c->data[b];
    for (uint32_t a = 64U; a < 74U; a++, b++)
        data[a] = c->data[b];
    for (uint32_t a = 80U; a < 90U; a++, b++)
        data[a] = c->data[b];
    for (uint32_t a = 96U; a < 106U; a++, b++)
        data[a] = c->data[b];

    // Hamming (16,11,4)，每行补 5 个校验位
    for (uint32_t a = 0U; a < 112U; a += 16U) {
        CHamming::encode16114(data + a);
    }

    // 第 8 行是前 7 行的列校验
    for (uint32_t a = 0U; a < 16U; a++) {
        data[a + 112U] = data[a + 0U] ^ data[a + 16U] ^ data[a + 32U] ^ data[a + 48U] ^ data[a + 64U] ^
                         data[a + 80U] ^ data[a + 96U];
    }

    // 按列读出（原实现的步进里 127 而不是 128，是刻意的，别“修正”）
    b = 0U;
    for (uint32_t a = 0U; a < 128U; a++) {
        c->raw[a] = data[b];
        b += 16U;
        if (b > 127U) {
            b -= 127U;
        }
    }
}

/// 把第 n（1…5）个突发该带的 32 bit 写进载荷，返回 LCSS。
static uint8_t get_embedded_data(dmr_core* c, uint8_t* data, uint8_t n) {
    if (n >= 1U && n < 5U) {
        n--;

        bool bits[40U];
        std::memset(bits, 0x00U, 40U * sizeof(bool));
        std::memcpy(bits + 4U, c->raw + n * 32U, 32U * sizeof(bool));

        uint8_t bytes[5U];
        bits_to_byte_be(bits + 0U, bytes[0U]);
        bits_to_byte_be(bits + 8U, bytes[1U]);
        bits_to_byte_be(bits + 16U, bytes[2U]);
        bits_to_byte_be(bits + 24U, bytes[3U]);
        bits_to_byte_be(bits + 32U, bytes[4U]);

        data[14U] = (data[14U] & 0xF0U) | (bytes[0U] & 0x0FU);
        data[15U] = bytes[1U];
        data[16U] = bytes[2U];
        data[17U] = bytes[3U];
        data[18U] = (data[18U] & 0x0FU) | (bytes[4U] & 0xF0U);

        switch (n) {
            case 0U:
                return 1U;
            case 3U:
                return 2U;
            default:
                return 3U;
        }
    }

    data[14U] &= 0xF0U;
    data[15U] = 0x00U;
    data[16U] = 0x00U;
    data[17U] = 0x00U;
    data[18U] &= 0x0FU;
    return 0U;
}

/// DMREMB：色码 + LCSS，再补 QR(16,7) 校验。
static void get_emb_data(dmr_core* c, uint8_t* data, uint8_t lcss) {
    uint8_t DMREMB[2U];
    DMREMB[0U] = (c->tx_cc << 4) & 0xF0U;
    DMREMB[0U] |= (lcss << 1) & 0x06U;
    DMREMB[1U] = 0x00U;

    encode_qr1676(DMREMB);

    data[13U] = (data[13U] & 0xF0U) | ((DMREMB[0U] >> 4U) & 0x0FU);
    data[14U] = (data[14U] & 0x0FU) | ((DMREMB[0U] << 4U) & 0xF0U);
    data[18U] = (data[18U] & 0xF0U) | ((DMREMB[1U] >> 4U) & 0x0FU);
    data[19U] = (data[19U] & 0x0FU) | ((DMREMB[1U] << 4U) & 0xF0U);
}

static void encode_qr1676(uint8_t* data) {
    uint32_t value = (data[0U] >> 1) & 0x7FU;
    uint32_t cksum = ENCODING_TABLE_1676[value];

    data[0U] = uint8_t(cksum >> 8);
    data[1U] = uint8_t(cksum & 0xFFU);
}

// MARK: - 语音头 / 结束符

/// slot type：高 4 位色码，低 4 位数据类型，外层套 Golay(20,8)。
static void get_slot_data(dmr_core* c, uint8_t* data) {
    uint8_t DMRSlotType[3U];
    DMRSlotType[0U] = (c->tx_cc << 4) & 0xF0U;
    DMRSlotType[0U] |= (c->data_type << 0) & 0x0FU;
    DMRSlotType[1U] = 0x00U;
    DMRSlotType[2U] = 0x00U;

    CGolay2087::encode(DMRSlotType);

    data[12U] = (data[12U] & 0xC0U) | ((DMRSlotType[0U] >> 2) & 0x3FU);
    data[13U] = (data[13U] & 0x0FU) | ((DMRSlotType[0U] << 6) & 0xC0U) | ((DMRSlotType[1U] >> 2) & 0x30U);
    data[19U] = (data[19U] & 0xF0U) | ((DMRSlotType[1U] >> 2) & 0x0FU);
    data[20U] = (data[20U] & 0x03U) | ((DMRSlotType[1U] << 6) & 0xC0U) | ((DMRSlotType[2U] >> 2) & 0x3CU);
}

/// 同步字。duplex = false 走 **MS（移动台）** 那一组 —— 热点在 MMDVM 里就是 simplex，
/// 用基站（BS）同步字等于冒充中继台，对端按 BS 解调会拿不到 LC。
static void add_dmr_data_sync(uint8_t* data, bool duplex) {
    const uint8_t* sync = duplex ? BS_SOURCED_DATA_SYNC : MS_SOURCED_DATA_SYNC;
    for (uint32_t i = 0U; i < 7U; i++) {
        data[i + 13U] = (data[i + 13U] & ~SYNC_MASK[i]) | sync[i];
    }
}

static void add_dmr_audio_sync(uint8_t* data, bool duplex) {
    const uint8_t* sync = duplex ? BS_SOURCED_AUDIO_SYNC : MS_SOURCED_AUDIO_SYNC;
    for (uint32_t i = 0U; i < 7U; i++) {
        data[i + 13U] = (data[i + 13U] & ~SYNC_MASK[i]) | sync[i];
    }
}

/// LC + RS(12,9) + 类型掩码 + slot type + BPTC(196,96) → 33 字节载荷。
static void full_lc_encode(dmr_core* c, uint8_t* data, uint8_t type) {
    uint8_t lcData[12U];
    uint8_t parity[4U];
    std::memset(lcData, 0, sizeof(lcData));
    lc_get_bytes(c, lcData);

    CRS129::encode(lcData, 9U, parity);

    switch (type) {
        case DT_VOICE_LC_HEADER:
            lcData[9U] = parity[2U] ^ VOICE_LC_HEADER_CRC_MASK[0U];
            lcData[10U] = parity[1U] ^ VOICE_LC_HEADER_CRC_MASK[1U];
            lcData[11U] = parity[0U] ^ VOICE_LC_HEADER_CRC_MASK[2U];
            break;

        case DT_TERMINATOR_WITH_LC:
            lcData[9U] = parity[2U] ^ TERMINATOR_WITH_LC_CRC_MASK[0U];
            lcData[10U] = parity[1U] ^ TERMINATOR_WITH_LC_CRC_MASK[1U];
            lcData[11U] = parity[0U] ^ TERMINATOR_WITH_LC_CRC_MASK[2U];
            break;

        default:
            return;
    }

    get_slot_data(c, data);
    c->bptc.encode(lcData, data);
}

/// 语音头 / 结束符：先铺数据同步字，再叠 LC。
static void encode_header(dmr_core* c, uint8_t type) {
    add_dmr_data_sync(c->frame + 20, false);
    c->data_type = type;
    full_lc_encode(c, c->frame + 20, type);
}

/// 语音突发：按超帧位置决定放音频同步字还是嵌入信令。
static void encode_data(dmr_core* c) {
    uint32_t n = (c->dmr_cnt - 1U) % 6U;

    if (!n) {
        c->data_type = DT_VOICE_SYNC;
        add_dmr_audio_sync(c->frame + 20, false);
        encode_embedded_data(c);
    } else {
        c->data_type = DT_VOICE;
        uint8_t lcss = get_embedded_data(c, c->frame + 20, uint8_t(n));
        get_emb_data(c, c->frame + 20, lcss);
    }
}

// MARK: - DMRD 帧头

/// 按 m_dataType / m_dmrcnt 组装 55 字节 DMRD。
///
/// 第 4 字节是帧序号（语音头 0，之后 1、2、3…），第 15 字节是标志位：
///   0x80 时隙2 / 0x40 单呼 / 0x20 控制帧 / 低 4 位 数据类型或超帧序号。
static void build_frame(dmr_core* c) {
    c->frame[0U] = 'D';
    c->frame[1U] = 'M';
    c->frame[2U] = 'R';
    c->frame[3U] = 'D';

    c->frame[5U] = uint8_t(c->tx_src >> 16);
    c->frame[6U] = uint8_t(c->tx_src >> 8);
    c->frame[7U] = uint8_t(c->tx_src >> 0);
    c->frame[8U] = uint8_t(c->tx_dst >> 16);
    c->frame[9U] = uint8_t(c->tx_dst >> 8);
    c->frame[10U] = uint8_t(c->tx_dst >> 0);
    c->frame[11U] = uint8_t(c->essid >> 24);
    c->frame[12U] = uint8_t(c->essid >> 16);
    c->frame[13U] = uint8_t(c->essid >> 8);
    c->frame[14U] = uint8_t(c->essid >> 0);

    c->frame[15U] = (c->tx_slot == 1U) ? 0x00U : 0x80U;
    c->frame[15U] |= (c->flco == FLCO_GROUP) ? 0x00U : 0x40U;

    if (c->data_type == DT_VOICE_SYNC) {
        c->frame[15U] |= 0x10U;
    } else if (c->data_type == DT_VOICE) {
        c->frame[15U] |= uint8_t((c->dmr_cnt - 1U) % 6U);
    } else {
        c->frame[15U] |= uint8_t(0x20U | c->data_type);
    }

    c->frame[4U] = uint8_t(c->dmr_cnt);
    std::memcpy(c->frame + 16U, &c->tx_stream, 4U);

    c->frame[53U] = 0;
    c->frame[54U] = 0;
}

// MARK: - 各帧构造

static int32_t put_login(dmr_core* c, uint8_t* out, int32_t cap) {
    if (out == NULL || cap < 8) {
        return 0;
    }
    std::memcpy(out, "RPTL", 4);
    out[4] = uint8_t(c->essid >> 24);
    out[5] = uint8_t(c->essid >> 16);
    out[6] = uint8_t(c->essid >> 8);
    out[7] = uint8_t(c->essid >> 0);
    return 8;
}

/// RPTK：id(4) + SHA256(挑战盐 ‖ 密码) 共 32 字节 = 40。
/// 明文 28 字节的老版本只给老 HBlink 用，BrandMeister 会当密码错。
static int32_t put_auth(dmr_core* c, const uint8_t* salt, uint8_t* out, int32_t cap) {
    if (out == NULL || cap < 40) {
        return 0;
    }
    std::memcpy(out, "RPTK", 4);
    out[4] = uint8_t(c->essid >> 24);
    out[5] = uint8_t(c->essid >> 16);
    out[6] = uint8_t(c->essid >> 8);
    out[7] = uint8_t(c->essid >> 0);

    uint8_t buffer[4U + 64U];
    std::memcpy(buffer, salt, 4U);
    size_t n = std::strlen(c->password);
    if (n > sizeof(c->password) - 1U) {
        n = sizeof(c->password) - 1U;
    }
    std::memcpy(buffer + 4U, c->password, n);

    CSHA256 sha;
    sha.buffer(buffer, uint32_t(n + 4U), out + 8U);
    return 40;
}

/// RPTC：4 + 4 + 294 = 302 字节。
///
/// 字段顺序照搬 DroidStar 的 sprintf 格式串（与 MMDVMHost 的 writeConfig 同源）：
/// 呼号 8 / 频率 9 / 频率 9 / 功率 2 / 色码 2 / 纬度 8 / 经度 9 / 天线高度 3 /
/// 位置 20 / 描述 19 / 时隙 1 / URL 124 / 软件 ID 40 / 包名 40。
///
/// 两个坑：
///   1. 数字字段必须零补齐（"01" 不是 "1"），少一位后面整体错位；
///   2. 不足部分补空格 0x20，不能补 NUL —— master 按 C 字符串解析会被截断。
static int32_t put_config(dmr_core* c, uint8_t* out, int32_t cap) {
    if (out == NULL || cap < 302) {
        return 0;
    }
    std::memcpy(out, "RPTC", 4);
    out[4] = uint8_t(c->essid >> 24);
    out[5] = uint8_t(c->essid >> 16);
    out[6] = uint8_t(c->essid >> 8);
    out[7] = uint8_t(c->essid >> 0);

    // 纬度 / 经度：DroidStar 用 sprintf("%08f"/"%09f", 0.0f) 得到
    // "0.000000" / "00.000000"，正好填满 %8.8s / %9.9s。App 不采集位置，固定 0。
    char latitude[20];
    char longitude[20];
    std::snprintf(latitude, sizeof(latitude), "%08f", 0.0);
    std::snprintf(longitude, sizeof(longitude), "%09f", 0.0);

    char block[400];
    int n = std::snprintf(block, sizeof(block),
                          "%-8.8s%09u%09u%02u%02u%8.8s%9.9s%03d%-20.20s%-19.19s%c%-124.124s%-40.40s%-40.40s",
                          c->callsign,
                          unsigned(c->frequency), unsigned(c->frequency),
                          1u, 1u,
                          latitude, longitude, 0,
                          c->location, c->description, '4',
                          c->url, c->software_id, c->package_id);
    if (n < 0) {
        n = 0;
    }
    if (n > 294) {
        n = 294;
    }

    std::memcpy(out + 8, block, size_t(n));
    std::memset(out + 8 + n, 0x20, size_t(294 - n));
    return 302;
}

static int32_t put_ping(dmr_core* c, uint8_t* out, int32_t cap) {
    if (out == NULL || cap < 11) {
        return 0;
    }
    std::memcpy(out, "RPTPING", 7);
    out[7] = uint8_t(c->essid >> 24);
    out[8] = uint8_t(c->essid >> 16);
    out[9] = uint8_t(c->essid >> 8);
    out[10] = uint8_t(c->essid >> 0);
    return 11;
}

static int32_t put_logout(dmr_core* c, uint8_t* out, int32_t cap) {
    if (out == NULL || cap < 9) {
        return 0;
    }
    std::memcpy(out, "RPTCL", 5);
    out[5] = uint8_t(c->essid >> 24);
    out[6] = uint8_t(c->essid >> 16);
    out[7] = uint8_t(c->essid >> 8);
    out[8] = uint8_t(c->essid >> 0);
    return 9;
}

// MARK: - 生命周期

dmr_core_t* dmr_core_create(void) {
    return new dmr_core();
}

void dmr_core_destroy(dmr_core_t* core) {
    delete core;
}

void dmr_core_set_params(dmr_core_t* c, const dmr_setup_t* setup) {
    if (c == NULL || setup == NULL) {
        return;
    }
    c->essid = setup->essid;
    c->dmr_id = setup->dmr_id;
    c->frequency = setup->frequency != 0U ? setup->frequency : 438800000U;
    c->color_code = setup->color_code > 15U ? 15U : setup->color_code;
    c->tx_cc = c->color_code;
    c->send_config = setup->send_config != 0;
}

void dmr_core_set_text(dmr_core_t* c, int32_t field, const char* value) {
    if (c == NULL) {
        return;
    }
    switch (field) {
        case DMR_TEXT_PASSWORD:
            copy_text(c->password, sizeof(c->password), value);
            break;
        case DMR_TEXT_CALLSIGN:
            copy_text(c->callsign, sizeof(c->callsign), value);
            break;
        case DMR_TEXT_LOCATION:
            copy_text(c->location, sizeof(c->location), value);
            break;
        case DMR_TEXT_DESCRIPTION:
            copy_text(c->description, sizeof(c->description), value);
            break;
        case DMR_TEXT_URL:
            copy_text(c->url, sizeof(c->url), value);
            break;
        case DMR_TEXT_SOFTWARE:
            copy_text(c->software_id, sizeof(c->software_id), value);
            break;
        case DMR_TEXT_PACKAGE:
            copy_text(c->package_id, sizeof(c->package_id), value);
            break;
        default:
            break;
    }
}

void dmr_core_set_talkgroup(dmr_core_t* c, uint32_t talkgroup) {
    if (c == NULL) {
        return;
    }
    c->tx_dst = talkgroup & 0xFFFFFFU;
}

uint32_t dmr_core_talkgroup(dmr_core_t* c) {
    return c == NULL ? 0U : c->tx_dst;
}

void dmr_core_set_color_code(dmr_core_t* c, uint8_t color_code) {
    if (c == NULL) {
        return;
    }
    c->color_code = color_code > 15U ? 15U : color_code;
    c->tx_cc = c->color_code;
}

int32_t dmr_core_status(dmr_core_t* c) {
    return c == NULL ? DMR_STATUS_DISCONNECTED : c->status;
}

void dmr_core_reset(dmr_core_t* c) {
    if (c == NULL) {
        return;
    }
    c->status = DMR_STATUS_DISCONNECTED;
    c->pongs = 0;
    c->tx_active = false;
    c->dmr_cnt = 0;
    c->tx_stream = 0;
}

// MARK: - 建链

int32_t dmr_core_login(dmr_core_t* c, uint8_t* out, int32_t cap) {
    if (c == NULL) {
        return 0;
    }
    // DroidStar 在 hostname_lookup 里先置 CONNECTING 再发 RPTL，
    // 只有这个状态下收到第一个 RPTACK 才会回 RPTK。
    c->status = DMR_STATUS_CONNECTING;
    return put_login(c, out, cap);
}

int32_t dmr_core_ping(dmr_core_t* c, uint8_t* out, int32_t cap) {
    if (c == NULL) {
        return 0;
    }
    return put_ping(c, out, cap);
}

int32_t dmr_core_logout(dmr_core_t* c, uint8_t* out, int32_t cap) {
    if (c == NULL) {
        return 0;
    }
    return put_logout(c, out, cap);
}

// MARK: - 收包

/// 把 DMRD 头部的地址 / 流号 / 时隙解析出来。
static void parse_dmr_head(const uint8_t* in, dmr_result_t* r) {
    r->src = (uint32_t(in[5]) << 16) | (uint32_t(in[6]) << 8) | uint32_t(in[7]);
    r->dst = (uint32_t(in[8]) << 16) | (uint32_t(in[9]) << 8) | uint32_t(in[10]);
    r->peer = (uint32_t(in[11]) << 24) | (uint32_t(in[12]) << 16) | (uint32_t(in[13]) << 8) | uint32_t(in[14]);
    r->stream_id = (uint32_t(in[16]) << 24) | (uint32_t(in[17]) << 16) | (uint32_t(in[18]) << 8) | uint32_t(in[19]);
    r->seq = int32_t(in[4]);
    r->slot = (in[15] & 0x80U) ? 2 : 1;
    r->is_private = (in[15] & 0x40U) ? 1 : 0;
}

int32_t dmr_core_receive(dmr_core_t* c, const uint8_t* in, int32_t len, dmr_result_t* r) {
    if (c == NULL || r == NULL) {
        return DMR_EVT_NONE;
    }

    std::memset(r, 0, sizeof(*r));
    r->event = DMR_EVT_NONE;
    r->status = c->status;

    if (in == NULL || len <= 0) {
        return DMR_EVT_NONE;
    }

    // ---- 会话被拒 / 被关 ----
    if (len >= 6 && std::memcmp(in, "MSTNAK", 6) == 0) {
        c->status = DMR_STATUS_DISCONNECTED;
        c->tx_active = false;
        r->event = DMR_EVT_NAK;
        r->status = c->status;
        return r->event;
    }
    if (len >= 5 && std::memcmp(in, "MSTCL", 5) == 0) {
        c->status = DMR_STATUS_DISCONNECTED;
        c->tx_active = false;
        r->event = DMR_EVT_CLOSED;
        r->status = c->status;
        return r->event;
    }

    // ---- 三段握手 ----
    // CONNECTING --RPTACK(盐)--> AUTH --RPTACK--> CONF --RPTACK--> CONNECTED
    if (c->status != DMR_STATUS_CONNECTED && len >= 6 && std::memcmp(in, "RPTACK", 6) == 0) {
        switch (c->status) {
            case DMR_STATUS_CONNECTING: {
                uint8_t salt[4] = {0, 0, 0, 0};
                if (len >= 10) {
                    std::memcpy(salt, in + 6, 4);
                }
                c->status = DMR_STATUS_AUTH;
                r->out_len = put_auth(c, salt, r->out, int32_t(sizeof(r->out)));
                r->event = DMR_EVT_AUTH;
                break;
            }
            case DMR_STATUS_AUTH: {
                if (!c->send_config) {
                    // 有的 master / 自建网关不收配置包，两段握手就够。
                    c->status = DMR_STATUS_CONNECTED;
                    r->event = DMR_EVT_CONNECTED;
                    break;
                }
                c->status = DMR_STATUS_CONF;
                r->out_len = put_config(c, r->out, int32_t(sizeof(r->out)));
                r->event = DMR_EVT_CONFIG;
                break;
            }
            case DMR_STATUS_CONF:
                c->status = DMR_STATUS_CONNECTED;
                r->event = DMR_EVT_CONNECTED;
                break;
            default:
                break;
        }
        r->status = c->status;
        return r->event;
    }

    // ---- 心跳应答 ----
    if (len == 11 && std::memcmp(in, "MSTPONG", 7) == 0) {
        c->pongs++;
        r->event = DMR_EVT_PONG;
        return r->event;
    }

    // ---- 语音 ----
    // 只认 55 字节 —— 参考实现 DroidStar 就是 `buf.size() == 55` 硬判，这里照抄。
    // 53 字节的窄帧（省掉 BER / RSSI 两个尾巴）在 HBlink3 与其它实现之间的载荷偏移
    // 并不一致，与其猜，不如丢一帧：读错偏移会把整段 LC 解成垃圾，还会污染解码器状态。
    if (len != DMR_FRAME_BYTES || std::memcmp(in, "DMRD", 4) != 0) {
        return DMR_EVT_NONE;
    }

    // 握手没走完就来的语音一律不处理（DroidStar 同样只在 CONNECTED_RW 之后才收）。
    if (c->status != DMR_STATUS_CONNECTED) {
        return DMR_EVT_NONE;
    }

    parse_dmr_head(in, r);

    const bool control = (in[15] & 0x20U) != 0;

    if (control) {
        std::memcpy(r->payload, in + 20, 33U);
        if (in[15] & 0x02U) {
            r->event = DMR_EVT_RX_EOT;
        } else if (in[15] & 0x01U) {
            r->event = DMR_EVT_RX_HEADER;
        } else {
            r->event = DMR_EVT_RX_OTHER;
        }
        r->data_type = int32_t(in[15] & 0x0FU);
        return r->event;
    }

    // 语音突发：把 33 字节载荷里的 3 个 AMBE 帧拼回连续的 27 字节。
    // 载荷第 13 字节低半字节是嵌入信令，语音比特要换成第 19 字节的低半字节。
    std::memcpy(r->payload, in + 20, 33U);
    std::memcpy(r->codec, r->payload, 14U);
    r->codec[13] &= 0xF0U;
    r->codec[13] |= (r->payload[19] & 0x0FU);
    std::memcpy(r->codec + 14, r->payload + 20, 13U);

    r->burst = int32_t(in[15] & 0x0FU);
    r->event = DMR_EVT_RX_VOICE;
    return r->event;
}

// MARK: - 发射

int32_t dmr_core_tx_begin(dmr_core_t* c, uint32_t talkgroup, uint8_t slot,
                          uint8_t color_code, uint8_t* out, int32_t cap) {
    if (c == NULL || out == NULL || cap < 55) {
        return 0;
    }

    c->tx_src = c->dmr_id & 0xFFFFFFU;
    c->tx_dst = talkgroup & 0xFFFFFFU;
    c->tx_slot = (slot == 1U) ? 1U : 2U;
    c->tx_cc = color_code > 15U ? 15U : color_code;
    c->flco = FLCO_GROUP;
    c->dmr_cnt = 0;
    c->tx_active = true;

    // 每次发射一个新的流号，同一段语音里所有帧共用它。
    // DroidStar 直接 `::rand()`；这里再异或一个自增序号，免得连续两次撞到同一个值。
    c->tx_stream = uint32_t(std::rand()) ^ (++g_stream_seq * 0x9E3779B9U);

    encode_header(c, DT_VOICE_LC_HEADER);
    build_frame(c);

    std::memcpy(out, c->frame, 55U);
    c->dmr_cnt++;
    return 55;
}

int32_t dmr_core_tx_burst(dmr_core_t* c, const uint8_t* codec27, uint8_t* out, int32_t cap) {
    if (c == NULL || out == NULL || cap < 55 || !c->tx_active) {
        return 0;
    }
    if (codec27 == NULL) {
        return 0;
    }

    // 27 字节 AMBE 拆成 13 + 1 个共享字节的两半 + 13，塞进载荷的 0…12 / 13 / 19 / 20…32。
    std::memcpy(c->frame + 20, codec27, 13U);
    c->frame[33U] = codec27[13] & 0xF0U;
    c->frame[39U] = codec27[13] & 0x0FU;
    std::memcpy(c->frame + 40, codec27 + 14, 13U);

    encode_data(c);
    build_frame(c);

    std::memcpy(out, c->frame, 55U);
    c->dmr_cnt++;
    return 55;
}

int32_t dmr_core_tx_end(dmr_core_t* c, uint8_t* out, int32_t cap) {
    if (c == NULL || out == NULL || cap < 55) {
        return 0;
    }
    if (!c->tx_active) {
        return 0;
    }

    encode_header(c, DT_TERMINATOR_WITH_LC);
    build_frame(c);

    std::memcpy(out, c->frame, 55U);
    c->dmr_cnt++;
    c->tx_active = false;
    return 55;
}

int32_t dmr_core_tx_active(dmr_core_t* c) {
    return (c != NULL && c->tx_active) ? 1 : 0;
}

int32_t dmr_core_tx_count(dmr_core_t* c) {
    return c == NULL ? 0 : int32_t(c->dmr_cnt);
}

void dmr_core_silence_codec(uint8_t* out27) {
    if (out27 == NULL) {
        return;
    }
    for (int i = 0; i < 3; ++i) {
        std::memcpy(out27 + i * 9, DMR_SILENCE_AMBE, 9U);
    }
}
