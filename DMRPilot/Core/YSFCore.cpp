//
//  YSFCore.cpp
//  DMRPilot
//
//  DroidStar `ysf.cpp`（GPL-3.0-or-later）的 C++ 直译，只删掉 Qt 与声码器部分。
//  下面的函数与参考实现一一对应，名字后面注了原文函数名，方便逐行对照：
//
//      ysf_decode_fich        ← CYSFFICH::decode（YSFFICH.cpp）
//      decode_dch_9           ← YSF::decode_vd1 / decode_header（9 字节/块）
//      decode_dch_5           ← YSF::decode_vd2（5 字节/块）
//      decode_vch             ← YSF::decode_dn 里的解交织 / 去白化 / 重排
//      write_fr_mode_data     ← YSF::writeDataFRModeData1 / 2
//      write_vd_mode2_data    ← YSF::writeVDMode2Data
//      encode_vch_vd2         ← YSF::generate_vch_vd2 + ysf_scramble
//      build_header / build_voice / build_terminator ← encode_header / encode_dv2
//
//  ⚠️ 参考实现里有两处「读未初始化内存」：`writeDataFRModeData` 的 `bytes[45]`
//  只写了前 25 字节却整块拷 45 字节，`writeVDMode2Data` 的 `bytes[25]` 只写前 13。
//  接收端的解交织表只覆盖前 200 / 100 bit，多出来的部分没人读，所以 DroidStar 能跑，
//  但那几段内容每次都是随机值。这里统一 memset 清零，输出是确定的。
//

#include "YSFCore.h"

#include <cstring>
#include <new>

#include "CRCenc.h"
#include "Golay24128.h"
#include "YSFConvolution.h"
#include "YSFFICH.h"

// MARK: - 句柄
//
// 必须定义在全局作用域：头文件里的 `ysf_core_t` 是 `struct ysf_core` 的 typedef，
// 放进匿名命名空间会变成另一个类型，所有 extern "C" 函数的签名就对不上了。

struct ysf_core {
    char     callsign[11];      ///< 空格补齐的 10 字节 + 结尾 0
    char     destination[11];   ///< 默认 "ALL       "
    int32_t  status;
    uint32_t txcnt;             ///< 本次发射已经组过多少个包（语音头也算）
};

namespace {

// MARK: - 常量

const uint8_t  YSF_SYNC_BYTES[] = {0xD4U, 0x71U, 0xC9U, 0x63U, 0x4DU};
const uint32_t YSF_SYNC_LENGTH_BYTES = 5U;

/// FI（帧类型）
const uint8_t YSF_FI_HEADER         = 0x00U;
const uint8_t YSF_FI_COMMUNICATIONS = 0x01U;
const uint8_t YSF_FI_TERMINATOR     = 0x02U;

/// DT（数据类型）
const uint8_t YSF_DT_VD_MODE1      = 0x00U;
const uint8_t YSF_DT_DATA_FR_MODE  = 0x01U;
const uint8_t YSF_DT_VD_MODE2      = 0x02U;
const uint8_t YSF_DT_VOICE_FR_MODE = 0x03U;

const uint32_t YSF_FRAME_LENGTH_BYTES = 120U;
/// 包头长度："YSFD" + gw10 + src10 + dst10 + 计数 1
const uint32_t YSF_HEADER_BYTES = 35U;

/// 载荷里语音/信令区的起点：同步 5 + FICH 25
const uint32_t YSF_PAYLOAD_BYTES = 30U;

const uint8_t WHITENING_DATA[] = {0x93U, 0xD7U, 0x51U, 0x21U, 0x9CU, 0x2FU, 0x6CU, 0xD0U, 0xEFU, 0x0FU,
                                  0xF8U, 0x3DU, 0xF1U, 0x73U, 0x20U, 0x94U, 0xEDU, 0x1EU, 0x7CU, 0xD8U};

const uint8_t BIT_MASK_TABLE[] = {0x80U, 0x40U, 0x20U, 0x10U, 0x08U, 0x04U, 0x02U, 0x01U};

#define WRITE_BIT(p, i, b) \
    p[(i) >> 3] = (b) ? (p[(i) >> 3] | BIT_MASK_TABLE[(i) & 7]) : (p[(i) >> 3] & ~BIT_MASK_TABLE[(i) & 7])
#define READ_BIT(p, i) (p[(i) >> 3] & BIT_MASK_TABLE[(i) & 7])

/// DCH 的 9 字节/块交织（200 bit 摊到 5 块 × 9 字节里）
const uint32_t INTERLEAVE_TABLE_9_20[] = {
    0U, 40U, 80U, 120U, 160U, 200U, 240U, 280U, 320U,
    2U, 42U, 82U, 122U, 162U, 202U, 242U, 282U, 322U,
    4U, 44U, 84U, 124U, 164U, 204U, 244U, 284U, 324U,
    6U, 46U, 86U, 126U, 166U, 206U, 246U, 286U, 326U,
    8U, 48U, 88U, 128U, 168U, 208U, 248U, 288U, 328U,
    10U, 50U, 90U, 130U, 170U, 210U, 250U, 290U, 330U,
    12U, 52U, 92U, 132U, 172U, 212U, 252U, 292U, 332U,
    14U, 54U, 94U, 134U, 174U, 214U, 254U, 294U, 334U,
    16U, 56U, 96U, 136U, 176U, 216U, 256U, 296U, 336U,
    18U, 58U, 98U, 138U, 178U, 218U, 258U, 298U, 338U,
    20U, 60U, 100U, 140U, 180U, 220U, 260U, 300U, 340U,
    22U, 62U, 102U, 142U, 182U, 222U, 262U, 302U, 342U,
    24U, 64U, 104U, 144U, 184U, 224U, 264U, 304U, 344U,
    26U, 66U, 106U, 146U, 186U, 226U, 266U, 306U, 346U,
    28U, 68U, 108U, 148U, 188U, 228U, 268U, 308U, 348U,
    30U, 70U, 110U, 150U, 190U, 230U, 270U, 310U, 350U,
    32U, 72U, 112U, 152U, 192U, 232U, 272U, 312U, 352U,
    34U, 74U, 114U, 154U, 194U, 234U, 274U, 314U, 354U,
    36U, 76U, 116U, 156U, 196U, 236U, 276U, 316U, 356U,
    38U, 78U, 118U, 158U, 198U, 238U, 278U, 318U, 358U};

/// DCH 的 5 字节/块交织（100 bit 摊到 5 块 × 5 字节里）
const uint32_t INTERLEAVE_TABLE_5_20[] = {
    0U, 40U, 80U, 120U, 160U,
    2U, 42U, 82U, 122U, 162U,
    4U, 44U, 84U, 124U, 164U,
    6U, 46U, 86U, 126U, 166U,
    8U, 48U, 88U, 128U, 168U,
    10U, 50U, 90U, 130U, 170U,
    12U, 52U, 92U, 132U, 172U,
    14U, 54U, 94U, 134U, 174U,
    16U, 56U, 96U, 136U, 176U,
    18U, 58U, 98U, 138U, 178U,
    20U, 60U, 100U, 140U, 180U,
    22U, 62U, 102U, 142U, 182U,
    24U, 64U, 104U, 144U, 184U,
    26U, 66U, 106U, 146U, 186U,
    28U, 68U, 108U, 148U, 188U,
    30U, 70U, 110U, 150U, 190U,
    32U, 72U, 112U, 152U, 192U,
    34U, 74U, 114U, 154U, 194U,
    36U, 76U, 116U, 156U, 196U,
    38U, 78U, 118U, 158U, 198U};

/// VCH 的 4×26 交织（104 bit 摊到 13 字节里）
const uint32_t INTERLEAVE_TABLE_26_4[] = {
    0U, 4U, 8U, 12U, 16U, 20U, 24U, 28U, 32U, 36U, 40U, 44U, 48U, 52U, 56U, 60U, 64U, 68U, 72U, 76U, 80U, 84U, 88U, 92U, 96U, 100U,
    1U, 5U, 9U, 13U, 17U, 21U, 25U, 29U, 33U, 37U, 41U, 45U, 49U, 53U, 57U, 61U, 65U, 69U, 73U, 77U, 81U, 85U, 89U, 93U, 97U, 101U,
    2U, 6U, 10U, 14U, 18U, 22U, 26U, 30U, 34U, 38U, 42U, 46U, 50U, 54U, 58U, 62U, 66U, 70U, 74U, 78U, 82U, 86U, 90U, 94U, 98U, 102U,
    3U, 7U, 11U, 15U, 19U, 23U, 27U, 31U, 35U, 39U, 43U, 47U, 51U, 55U, 59U, 63U, 67U, 71U, 75U, 79U, 83U, 87U, 91U, 95U, 99U, 103U};

/// VCH 的扰码（`ysf_scramble` 里那张表，只用在 104 bit 上）
const uint8_t YSF_SCRAMBLE_CODE[180] = {
    1, 0, 0, 1, 0, 0, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1,
    0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1,
    1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1,
    0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 0, 0,
    1, 1, 1, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 1, 1, 1, 1, 0, 1,
    1, 1, 1, 1, 0, 0, 0, 1, 0, 1, 1, 1, 0, 0, 1, 1,
    0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1, 0, 0,
    1, 1, 1, 0, 1, 1, 0, 1, 0, 0, 0, 1, 1, 1, 1, 0,
    0, 1, 1, 1, 1, 1, 0, 0, 1, 1, 0, 1, 1, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0};

// MARK: - 辅助

/// 呼号写进固定宽度字段：不足补空格，**不是** 0 结尾。
void set_padded(char* dst, const char* src) {
    ::memset(dst, ' ', YSF_CALLSIGN_BYTES);
    dst[YSF_CALLSIGN_BYTES] = '\0';
    if (src == nullptr) {
        return;
    }
    size_t n = ::strlen(src);
    if (n > YSF_CALLSIGN_BYTES) {
        n = YSF_CALLSIGN_BYTES;
    }
    ::memcpy(dst, src, n);
}

/// 把 10 字节定长字段转成可打印字符串（去掉尾部空格）。
void copy_trimmed(uint8_t* dst, const uint8_t* src) {
    int32_t n = (int32_t)YSF_CALLSIGN_BYTES;
    while (n > 0 && src[n - 1] == ' ') {
        n--;
    }
    ::memcpy(dst, src, (size_t)n);
    dst[n] = '\0';
}

// MARK: - 解交织 / 纠错

/// 9 字节/块的 DCH（语音头、VD 模式 1）→ 20 字节呼号数据。CRC 不过返回 false。
bool decode_dch_9(const uint8_t* data30, uint8_t* out20) {
    uint8_t dch[45];
    const uint8_t* p1 = data30;
    uint8_t* p2 = dch;
    for (uint32_t i = 0U; i < 5U; i++) {
        ::memcpy(p2, p1, 9U);
        p1 += 18U;
        p2 += 9U;
    }

    CYSFConvolution conv;
    conv.start();

    for (uint32_t i = 0U; i < 180U; i++) {
        uint32_t n = INTERLEAVE_TABLE_9_20[i];
        uint8_t s0 = READ_BIT(dch, n) ? 1U : 0U;
        n++;
        uint8_t s1 = READ_BIT(dch, n) ? 1U : 0U;
        conv.decode(s0, s1);
    }

    uint8_t output[23];
    ::memset(output, 0, sizeof(output));
    conv.chainback(output, 176U);

    if (!CCRC::checkCCITT162(output, 22U)) {
        return false;
    }
    for (uint32_t i = 0U; i < 20U; i++) {
        output[i] ^= WHITENING_DATA[i];
    }
    ::memcpy(out20, output, 20U);
    return true;
}

/// 5 字节/块的 DCH（VD 模式 2）→ 10 字节呼号数据。CRC 不过返回 false。
bool decode_dch_5(const uint8_t* data30, uint8_t* out10) {
    uint8_t dch[25];
    const uint8_t* p1 = data30;
    uint8_t* p2 = dch;
    for (uint32_t i = 0U; i < 5U; i++) {
        ::memcpy(p2, p1, 5U);
        p1 += 18U;
        p2 += 5U;
    }

    CYSFConvolution conv;
    conv.start();

    for (uint32_t i = 0U; i < 100U; i++) {
        uint32_t n = INTERLEAVE_TABLE_5_20[i];
        uint8_t s0 = READ_BIT(dch, n) ? 1U : 0U;
        n++;
        uint8_t s1 = READ_BIT(dch, n) ? 1U : 0U;
        conv.decode(s0, s1);
    }

    uint8_t output[13];
    ::memset(output, 0, sizeof(output));
    conv.chainback(output, 96U);

    if (!CCRC::checkCCITT162(output, 12U)) {
        return false;
    }
    for (uint32_t i = 0U; i < 10U; i++) {
        output[i] ^= WHITENING_DATA[i];
    }
    ::memcpy(out10, output, 10U);
    return true;
}

/// 5 个 13 字节 VCH → 5 个 49 bit AMBE（每帧 7 字节，MSB 优先）。
///
/// 和参考实现的 `decode_dn` 后半段一致：VCH 从每块的第 5 字节起（bit 偏移 40），
/// 解交织 104 bit → 去白化 → 拆成 12 + 12 + 25 三段参数 → 拼回 49 bit。
void decode_vch(const uint8_t* data30, uint8_t* out35) {
    uint32_t offset = 40U;   // 单位是 bit

    for (uint32_t j = 0U; j < 5U; j++, offset += 144U) {
        uint8_t vch[13];
        ::memset(vch, 0, sizeof(vch));

        for (uint32_t i = 0U; i < 104U; i++) {
            uint32_t n = INTERLEAVE_TABLE_26_4[i];
            WRITE_BIT(vch, i, READ_BIT(data30, offset + n) ? 1U : 0U);
        }

        for (uint32_t i = 0U; i < 13U; i++) {
            vch[i] ^= WHITENING_DATA[i];
        }

        uint32_t dat_a = 0U;
        uint32_t dat_b = 0U;
        uint32_t dat_c = 0U;

        for (uint32_t i = 0U; i < 12U; i++) {
            dat_a <<= 1U;
            if (READ_BIT(vch, 3U * i + 1U)) {
                dat_a |= 0x01U;
            }
        }
        for (uint32_t i = 0U; i < 12U; i++) {
            dat_b <<= 1U;
            if (READ_BIT(vch, 3U * (i + 12U) + 1U)) {
                dat_b |= 0x01U;
            }
        }
        for (uint32_t i = 0U; i < 3U; i++) {
            dat_c <<= 1U;
            if (READ_BIT(vch, 3U * (i + 24U) + 1U)) {
                dat_c |= 0x01U;
            }
        }
        for (uint32_t i = 0U; i < 22U; i++) {
            dat_c <<= 1U;
            if (READ_BIT(vch, i + 81U)) {
                dat_c |= 0x01U;
            }
        }

        uint8_t frame[7];
        ::memset(frame, 0, sizeof(frame));
        for (uint32_t i = 0U; i < 12U; i++) {
            bool s1 = (dat_a << (i + 20U)) & 0x80000000U;
            bool s2 = (dat_b << (i + 20U)) & 0x80000000U;
            WRITE_BIT(frame, i, s1);
            WRITE_BIT(frame, i + 12U, s2);
        }
        for (uint32_t i = 0U; i < 25U; i++) {
            bool s = (dat_c << (i + 7U)) & 0x80000000U;
            WRITE_BIT(frame, i + 24U, s);
        }

        ::memcpy(out35 + 7U * j, frame, 7U);
    }
}

// MARK: - 组帧

/// 一包 10 字节 DCH 数据（头部两组、或 VD2 里的一组）写进 5 块 × 9 字节。
/// `offset` 是块内偏移：CSD1 = 0，CSD2 = 9。
void write_fr_mode_data(const uint8_t* dt20, uint8_t* payload, uint32_t offset) {
    uint8_t output[25];
    ::memset(output, 0, sizeof(output));
    for (uint32_t i = 0U; i < 20U; i++) {
        output[i] = dt20[i] ^ WHITENING_DATA[i];
    }
    CCRC::addCCITT162(output, 22U);
    output[22] = 0x00U;

    uint8_t convolved[45];
    ::memset(convolved, 0, sizeof(convolved));
    CYSFConvolution conv;
    conv.encode(output, convolved, 180U);

    // 参考实现在这里没清零，多出来的 20 字节是随机值（接收端不读）。
    uint8_t bytes[45];
    ::memset(bytes, 0, sizeof(bytes));

    uint32_t j = 0U;
    for (uint32_t i = 0U; i < 180U; i++) {
        uint32_t n = INTERLEAVE_TABLE_9_20[i];
        bool s0 = READ_BIT(convolved, j) != 0U;
        j++;
        bool s1 = READ_BIT(convolved, j) != 0U;
        j++;
        WRITE_BIT(bytes, n, s0);
        n++;
        WRITE_BIT(bytes, n, s1);
    }

    for (uint32_t i = 0U; i < 5U; i++) {
        ::memcpy(payload + YSF_PAYLOAD_BYTES + offset + 18U * i, bytes + 9U * i, 9U);
    }
}

/// VD 模式 2 的 10 字节 DCH（5 字节/块），只写每块前 5 字节，后面 13 字节留给 VCH。
void write_vd_mode2_data(const uint8_t* dt10, uint8_t* payload) {
    uint8_t dt_tmp[13];
    ::memset(dt_tmp, 0, sizeof(dt_tmp));
    ::memcpy(dt_tmp, dt10, 10U);
    for (uint32_t i = 0U; i < 10U; i++) {
        dt_tmp[i] ^= WHITENING_DATA[i];
    }
    CCRC::addCCITT162(dt_tmp, 12U);
    dt_tmp[12] = 0x00U;

    uint8_t convolved[25];
    ::memset(convolved, 0, sizeof(convolved));
    CYSFConvolution conv;
    conv.start();
    conv.encode(dt_tmp, convolved, 100U);

    uint8_t bytes[25];
    ::memset(bytes, 0, sizeof(bytes));

    uint32_t j = 0U;
    for (uint32_t i = 0U; i < 100U; i++) {
        uint32_t n = INTERLEAVE_TABLE_5_20[i];
        bool s0 = READ_BIT(convolved, j) != 0U;
        j++;
        bool s1 = READ_BIT(convolved, j) != 0U;
        j++;
        WRITE_BIT(bytes, n, s0);
        n++;
        WRITE_BIT(bytes, n, s1);
    }

    for (uint32_t i = 0U; i < 5U; i++) {
        ::memcpy(payload + YSF_PAYLOAD_BYTES + 18U * i, bytes + 5U * i, 5U);
    }
}

/// 49 bit AMBE → 13 字节 VCH（参考实现的 generate_vch_vd2 + ysf_scramble）。
void encode_vch_vd2(const uint8_t* bits49, uint8_t* vch13) {
    uint8_t buf[104];
    uint8_t result[104];
    ::memset(buf, 0, sizeof(buf));
    ::memset(result, 0, sizeof(result));

    // 每个参数 bit 重复三遍（1/3 重复码），尾部 22 bit 原样
    for (int i = 0; i < 27; i++) {
        buf[0 + i * 3] = bits49[i];
        buf[1 + i * 3] = bits49[i];
        buf[2 + i * 3] = bits49[i];
    }
    ::memcpy(buf + 81, bits49 + 27, 22U);
    buf[103] = 0U;

    for (int i = 0; i < 104; i++) {
        buf[i] ^= YSF_SCRAMBLE_CODE[i];
    }

    // 4 × 26 的转置交织
    const int x = 4;
    const int y = 26;
    for (int i = 0; i < x; i++) {
        for (int j = 0; j < y; j++) {
            result[i + j * x] = buf[j + i * y];
        }
    }

    ::memset(vch13, 0, 13U);
    for (int i = 0; i < 13; i++) {
        for (int j = 0; j < 8; j++) {
            vch13[i] |= (uint8_t)(result[i * 8 + j] << (7 - j));
        }
    }
}

/// 包头：4 字节 "YSFD" + 网关 / 源 / 目的 + 计数。
void write_packet_header(const ysf_core* core, uint8_t* out, bool eot) {
    ::memcpy(out + 0U, "YSFD", 4U);
    ::memcpy(out + 4U, core->callsign, YSF_CALLSIGN_BYTES);
    ::memcpy(out + 14U, core->callsign, YSF_CALLSIGN_BYTES);
    ::memcpy(out + 24U, core->destination, YSF_CALLSIGN_BYTES);

    if (eot) {
        // 结束符带 +1；语音头不带计数（参考实现写 0）
        out[34] = (uint8_t)(((core->txcnt & 0x7fU) << 1U) | 1U);
    } else {
        out[34] = 0U;
    }
}

void set_fich(CYSFFICH& fich, uint8_t fi, uint32_t fn, uint8_t dt) {
    fich.setFI(fi);
    fich.setCS(2U);          // 2 = 12.5 kHz 带宽的 C4FM
    fich.setCM(0U);          // 0 = 组呼
    fich.setBN(0U);
    fich.setBT(0U);
    fich.setFN((uint8_t)fn);
    fich.setFT(6U);          // 一个超帧 6 帧
    fich.setDev(0U);
    fich.setMR(0U);
    fich.setVoIP(false);
    fich.setDT(dt);
    fich.setSQL(false);
    fich.setSQ(0U);
}

int32_t build_header(const ysf_core* core, bool eot, uint8_t* out, int32_t cap) {
    if (out == nullptr || cap < YSF_PACKET_BYTES) {
        return 0;
    }
    ::memset(out, 0, YSF_PACKET_BYTES);

    write_packet_header(core, out, eot);

    uint8_t* payload = out + YSF_HEADER_BYTES;
    ::memcpy(payload, YSF_SYNC_BYTES, YSF_SYNC_LENGTH_BYTES);

    CYSFFICH fich;
    set_fich(fich, eot ? YSF_FI_TERMINATOR : YSF_FI_HEADER, 0U, YSF_DT_VD_MODE2);
    fich.encode(payload);

    // CSD1 = 10 个 '*'（无线电台号占位）+ 自己的呼号
    // CSD2 = 呼号 + 呼号（源 / 目的都填自己，参考实现就是这样，反射器只认 CSV）
    uint8_t csd1[20];
    uint8_t csd2[20];
    ::memset(csd1, '*', YSF_CALLSIGN_BYTES);
    ::memcpy(csd1 + YSF_CALLSIGN_BYTES, core->callsign, YSF_CALLSIGN_BYTES);
    ::memcpy(csd2, core->callsign, YSF_CALLSIGN_BYTES);
    ::memcpy(csd2 + YSF_CALLSIGN_BYTES, core->callsign, YSF_CALLSIGN_BYTES);

    write_fr_mode_data(csd1, payload, 0U);
    write_fr_mode_data(csd2, payload, 9U);

    return (int32_t)YSF_PACKET_BYTES;
}

/// 第 fn 帧要在 DCH 里带的 10 字节内容（参考实现 encode_dv2 的 switch）。
void vd2_dch_for_frame(const ysf_core* core, uint32_t fn, uint8_t* out10) {
    static const uint8_t ft70d1[10] = {0x01, 0x22, 0x61, 0x5f, 0x2b, 0x03, 0x11, 0x00, 0x00, 0x00};

    switch (fn) {
    case 0:
        // 目的：不单独填，交给反射器按 ALL 分发
        ::memset(out10, '*', YSF_CALLSIGN_BYTES);
        break;
    case 1:
    case 2:
    case 3:
        // 源 / 下行 / 上行 都是自己
        ::memcpy(out10, core->callsign, YSF_CALLSIGN_BYTES);
        break;
    case 6:
        ::memcpy(out10, ft70d1, YSF_CALLSIGN_BYTES);
        break;
    default:
        ::memset(out10, ' ', YSF_CALLSIGN_BYTES);
        break;
    }
}

}  // namespace

// MARK: - 生命周期

ysf_core_t* ysf_core_create(void) {
    ysf_core* core = new (std::nothrow) ysf_core();
    if (core == nullptr) {
        return nullptr;
    }
    set_padded(core->callsign, "N0CALL");
    set_padded(core->destination, "ALL");
    core->status = YSF_STATUS_DISCONNECTED;
    core->txcnt = 0U;
    return core;
}

void ysf_core_destroy(ysf_core_t* core) {
    delete core;
}

void ysf_core_set_callsign(ysf_core_t* core, const char* callsign) {
    if (core == nullptr) {
        return;
    }
    set_padded(core->callsign, callsign);
}

void ysf_core_set_destination(ysf_core_t* core, const char* destination) {
    if (core == nullptr) {
        return;
    }
    set_padded(core->destination, (destination == nullptr || destination[0] == '\0') ? "ALL" : destination);
}

int32_t ysf_core_status(ysf_core_t* core) {
    return core == nullptr ? YSF_STATUS_DISCONNECTED : core->status;
}

void ysf_core_reset(ysf_core_t* core) {
    if (core == nullptr) {
        return;
    }
    core->status = YSF_STATUS_DISCONNECTED;
    core->txcnt = 0U;
}

// MARK: - 建链

int32_t ysf_core_login(ysf_core_t* core, uint8_t* out, int32_t cap) {
    if (core == nullptr || out == nullptr || cap < 14) {
        return 0;
    }
    ::memcpy(out, "YSFP", 4U);
    ::memcpy(out + 4U, core->callsign, YSF_CALLSIGN_BYTES);
    core->status = YSF_STATUS_CONNECTING;
    return 14;
}

int32_t ysf_core_ping(ysf_core_t* core, uint8_t* out, int32_t cap) {
    if (core == nullptr || out == nullptr || cap < 14) {
        return 0;
    }
    ::memcpy(out, "YSFP", 4U);
    ::memcpy(out + 4U, core->callsign, YSF_CALLSIGN_BYTES);
    return 14;
}

int32_t ysf_core_logout(ysf_core_t* core, uint8_t* out, int32_t cap) {
    if (core == nullptr || out == nullptr || cap < 14) {
        return 0;
    }
    ::memcpy(out, "YSFU", 4U);
    ::memcpy(out + 4U, core->callsign, YSF_CALLSIGN_BYTES);
    core->status = YSF_STATUS_DISCONNECTED;
    return 14;
}

// MARK: - 收包

int32_t ysf_core_receive(ysf_core_t* core,
                         const uint8_t* in,
                         int32_t len,
                         ysf_result_t* result) {
    if (core == nullptr || in == nullptr || result == nullptr) {
        return YSF_EVT_NONE;
    }

    ::memset(result, 0, sizeof(*result));
    result->event = YSF_EVT_NONE;
    result->status = core->status;

    // FCS 反射器是 7 / 130 字节的另一套封装（PIN G / CLOSE），这里不支持：
    // 130 字节的包直接当未知帧丢掉，界面上会看到「收到无法识别的包」。
    if (len == 14) {
        // 服务器对 YSFP 的回应就是 14 字节；内容不固定，收到就算连通。
        if (core->status == YSF_STATUS_CONNECTING) {
            core->status = YSF_STATUS_ONLINE;
            result->status = core->status;
            result->event = YSF_EVT_CONNECTED;
        }
        return result->event;
    }

    if (len == 10 && ::memcmp(in, "ONLINE", 6U) == 0) {
        result->event = YSF_EVT_PONG;
        return result->event;
    }

    if (len < (int32_t)(YSF_HEADER_BYTES + YSF_FRAME_LENGTH_BYTES) ||
        ::memcmp(in, "YSFD", 4U) != 0) {
        return YSF_EVT_NONE;
    }

    const uint8_t* payload = in + YSF_HEADER_BYTES;

    // 包头里那三段呼号：网关、源、目的。语音流里的源更准的版本在 DCH 里。
    ::memcpy(result->gw, in + 4U, YSF_CALLSIGN_BYTES);
    result->gw[YSF_CALLSIGN_BYTES] = '\0';
    ::memcpy(result->src, in + 14U, YSF_CALLSIGN_BYTES);
    result->src[YSF_CALLSIGN_BYTES] = '\0';
    ::memcpy(result->dst, in + 24U, YSF_CALLSIGN_BYTES);
    result->dst[YSF_CALLSIGN_BYTES] = '\0';
    result->frame_counter = (int32_t)(in[34] >> 1);

    CYSFFICH fich;
    if (!fich.decode(payload)) {
        // FICH 自身有 CCITT-16 + Golay + 卷积码保护，校验不过就是坏包。
        return YSF_EVT_NONE;
    }

    result->fi = (int32_t)fich.getFI();
    result->dt = (int32_t)fich.getDT();
    result->fn = (int32_t)fich.getFN();
    result->ft = (int32_t)fich.getFT();
    result->voip = fich.getVoIP() ? 1 : 0;

    // 载荷里的信令/语音区从第 30 字节开始（同步 5 + FICH 25 之后）
    const uint8_t* body = payload + YSF_PAYLOAD_BYTES;

    switch (result->fi) {
    case YSF_FI_HEADER: {
        uint8_t dch[20];
        if (decode_dch_9(body, dch)) {
            // 前 10 字节是目的，后 10 是源
            uint8_t dest[11];
            uint8_t src[11];
            copy_trimmed(dest, dch);
            copy_trimmed(src, dch + YSF_CALLSIGN_BYTES);
            ::memcpy(result->dst, dest, ::strlen((const char*)dest) + 1U);
            ::memcpy(result->src, src, ::strlen((const char*)src) + 1U);
        }
        result->event = YSF_EVT_RX_HEADER;
        break;
    }

    case YSF_FI_TERMINATOR:
        result->event = YSF_EVT_RX_END;
        break;

    case YSF_FI_COMMUNICATIONS:
        if (result->dt == YSF_DT_VOICE_FR_MODE) {
            // 全速率语音（VW 模式，4400 bps）：要另一套声码器，只报事件不解码。
            result->event = YSF_EVT_RX_OTHER;
            break;
        }
        if (result->dt == YSF_DT_DATA_FR_MODE) {
            // 数据帧（文字 / 图片），不处理。
            result->event = YSF_EVT_RX_OTHER;
            break;
        }

        {
            // VD 模式 1 / 2 都是 2450 bps，只是 DCH 宽度不同
            uint8_t dch[20];
            bool hasDch = false;
            if (result->dt == YSF_DT_VD_MODE1) {
                hasDch = decode_dch_9(body, dch);
            } else {
                hasDch = decode_dch_5(body, dch);
            }
            if (hasDch) {
                // 帧号 0 是目的，1 是源（参考实现 decode_dn 的 switch）
                uint8_t text[11];
                copy_trimmed(text, dch);
                if (result->fn == 0) {
                    ::memcpy(result->dst, text, ::strlen((const char*)text) + 1U);
                } else if (result->fn == 1) {
                    ::memcpy(result->src, text, ::strlen((const char*)text) + 1U);
                }
            }
        }

        decode_vch(body, result->codec);
        result->codec_len = YSF_CODEC_BYTES;
        result->event = YSF_EVT_RX_VOICE;
        break;

    default:
        result->event = YSF_EVT_RX_OTHER;
        break;
    }

    return result->event;
}

// MARK: - 发射

int32_t ysf_core_tx_begin(ysf_core_t* core, uint8_t* out, int32_t cap) {
    if (core == nullptr) {
        return 0;
    }
    core->txcnt = 0U;
    int32_t n = build_header(core, false, out, cap);
    if (n > 0) {
        core->txcnt = 1U;
    }
    return n;
}

int32_t ysf_core_tx_voice(ysf_core_t* core,
                          const uint8_t* codec35,
                          uint8_t* out,
                          int32_t cap) {
    if (core == nullptr || codec35 == nullptr || out == nullptr || cap < YSF_PACKET_BYTES) {
        return 0;
    }

    ::memset(out, 0, YSF_PACKET_BYTES);
    write_packet_header(core, out, false);
    // 语音包的计数是「第几包 << 1」
    out[34] = (uint8_t)((core->txcnt & 0x7fU) << 1U);

    uint8_t* payload = out + YSF_HEADER_BYTES;
    ::memcpy(payload, YSF_SYNC_BYTES, YSF_SYNC_LENGTH_BYTES);

    uint32_t fn = (core->txcnt - 1U) % 7U;

    CYSFFICH fich;
    set_fich(fich, YSF_FI_COMMUNICATIONS, fn, YSF_DT_VD_MODE2);
    fich.encode(payload);

    // 这一包 5 帧共用同一组 DCH；每帧的 VCH 各自不同
    uint8_t dch[10];
    vd2_dch_for_frame(core, fn, dch);
    write_vd_mode2_data(dch, payload);

    for (uint32_t frame = 0U; frame < YSF_CODEC_FRAMES; frame++) {
        const uint8_t* src = codec35 + 7U * frame;

        uint8_t bits49[49];
        for (uint32_t i = 0U; i < 49U; i++) {
            bits49[i] = READ_BIT(src, i) ? 1U : 0U;
        }

        uint8_t vch[13];
        encode_vch_vd2(bits49, vch);
        ::memcpy(payload + YSF_PAYLOAD_BYTES + 18U * frame + 5U, vch, 13U);
    }

    core->txcnt++;
    return (int32_t)YSF_PACKET_BYTES;
}

int32_t ysf_core_tx_end(ysf_core_t* core, uint8_t* out, int32_t cap) {
    if (core == nullptr) {
        return 0;
    }
    int32_t n = build_header(core, true, out, cap);
    core->txcnt = 0U;
    return n;
}

int32_t ysf_core_tx_count(ysf_core_t* core) {
    return core == nullptr ? 0 : (int32_t)core->txcnt;
}
