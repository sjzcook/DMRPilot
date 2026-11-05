//
//  HalfrateCore.swift
//  DMRPilot
//
//  AMBE+2 半速率编解码器的基础层：定点/饱和转换、codec 自带的 log2/exp2/sqrt
//  近似、余弦表、512 点 FFT。
//
//  移植自 DroidStar 的 mbe/fastmath.cc、mbe/fft.cc、mbe/numeric.h。
//  ⚠️ codec 的输出依赖这些近似函数的精确结果，所以不能换成系统 libm。
//

import Foundation

enum HRCore {

    // MARK: - 尺寸

    static let frameBits = 49
    static let frameBytes = 7
    static let frameSamples = 160
    static let harmonicSlots = 58
    static let maxHarmonics = 56
    static let resetHarmonicCount = 30
    static let airBytes = 9

    // MARK: - 余弦表

    /// cos(2πi / 8192)，一轮。C++ 侧是生成的常量表，这里启动时用 Double 现算，
    /// 与原始 float 表的差异在 1 ULP 量级，对音频无影响。
    static let cosine: [Float] = (0..<8192).map {
        Float(cos(2.0 * Double.pi * Double($0) / 8192.0))
    }

    /// 表索引，自动按 8192 取模，避免越界崩溃。
    @inline(__always)
    static func cosAt(_ index: Int) -> Float {
        cosine[index & 8191]
    }

    // MARK: - 饱和转换

    @inline(__always)
    static func toInt32Sat(_ x: Float) -> Int32 {
        if x != x { return 0 }
        if x >= 2_147_483_648.0 { return Int32.max }
        if x <= -2_147_483_648.0 { return Int32.min }
        return Int32(x)
    }

    @inline(__always)
    static func toInt32Sat(_ x: Double) -> Int32 {
        if x != x { return 0 }
        if x >= 2_147_483_648.0 { return Int32.max }
        if x <= -2_147_483_648.0 { return Int32.min }
        return Int32(x)
    }

    @inline(__always)
    static func toInt64Sat(_ x: Double) -> Int64 {
        if x != x { return 0 }
        if x >= 9_223_372_036_854_775_808.0 { return Int64.max }
        if x <= -9_223_372_036_854_775_808.0 { return Int64.min }
        return Int64(x)
    }

    /// x * 2^bits 转 int64，截断并饱和（对应 C++ 的 to_fixed64）
    @inline(__always)
    static func toFixed64(_ x: Float, _ bits: Int) -> Int64 {
        toInt64Sat(Double(x) * Double(UInt64(1) << UInt64(bits)))
    }

    // MARK: - 位与浮点互转

    @inline(__always)
    static func floatBits(_ f: Float) -> UInt32 { f.bitPattern }

    @inline(__always)
    static func floatFromBits(_ u: UInt32) -> Float { Float(bitPattern: u) }

    // MARK: - fast_log2 / fast_exp2 / fast_sqrt

    private static let smallestNormal: Float = 0x1p-126
    private static let sqrt2: Float = 1.41421354
    private static let twoOverLn2: Float = 2.8853900817779268
    private static let ln2: Float = 0.6931471824645996

    /// atanh 级数展开，输入折叠到 [sqrt(1/2), sqrt(2))
    static func fastLog2(_ x: Float) -> Float {
        if !(x >= smallestNormal) { return -126.0 }

        let bits = floatBits(x)
        var m = floatFromBits(0x3f80_0000 | (bits & 0x7f_ffff))
        let half = m * 0.5
        let fold = m > sqrt2
        if fold { m = half }
        let exponent = (fold ? -126 : -127) + Int(bits >> 23)

        // log(m) = 2 atanh(t)，t = (m - 1) / (m + 1)
        let t = (m - 1.0) / (m + 1.0)
        let t2 = t * t
        var p = t2 * (1.0 / 9.0)
        p = p + 1.0 / 7.0
        p = t2 * p
        p = p + 1.0 / 5.0
        p = t2 * p
        p = p + 1.0 / 3.0
        p = t2 * p
        p = p + 1.0
        var r = t * p
        r = r * twoOverLn2
        return r + Float(exponent)
    }

    /// 2^x：整数部分四舍五入进指数，余项走 7 阶泰勒展开
    static func fastExp2(_ x: Float) -> Float {
        if x != x { return 0.0 }

        var value = x
        value = value < -126.0 ? -126.0 : value
        value = value > 127.0 ? 127.0 : value

        // 加 200.5 之后截断即"四舍五入"
        var whole = Int(value + 0.5 + 200.0) - 200
        var f = value - Float(whole)
        f = f * ln2

        var p = f * (1.0 / 5040.0)
        p = p + 1.0 / 720.0
        p = f * p
        p = p + 1.0 / 120.0
        p = f * p
        p = p + 1.0 / 24.0
        p = f * p
        p = p + 1.0 / 6.0
        p = f * p
        p = p + 0.5
        p = f * p
        p = p + 1.0
        var r = f * p
        r = r + 1.0

        whole = whole > -126 ? whole : -126
        whole = whole < 127 ? whole : 127
        let scale = floatFromBits(0x3f80_0000 &+ (UInt32(bitPattern: Int32(whole)) &<< 23))
        return r * scale
    }

    static func fastSqrt(_ x: Float) -> Float {
        if !(x > smallestNormal) { return 0.0 }
        return fastExp2(fastLog2(x) * 0.5)
    }

    @inline(__always)
    static func minNum(_ a: Float, _ b: Float) -> Float { a < b ? a : b }

    @inline(__always)
    static func maxNum(_ a: Float, _ b: Float) -> Float { a > b ? a : b }

    // MARK: - cos(2πx)，表内线性插值

    static func cosineInterpolated(_ x: Float) -> Float {
        let s = x * 8192.0
        let i = toFixed64(x, 13) - (s < 0.0 ? 1 : 0)
        let fraction = s - Float(i)
        let index0 = Int(UInt64(bitPattern: i) & 0x1fff)
        let u = UInt32(bitPattern: Int32(truncatingIfNeeded: i))
        let index1 = Int((u &+ 1) & 0x1fff)
        let t0 = cosine[index0]
        let t1 = cosine[index1]
        return t0 + fraction * (t1 - t0)
    }

    // MARK: - 512 点 FFT（内核 e^-j，不缩放）

    static func fft512(_ re: inout [Float], _ im: inout [Float]) {
        // 位倒序
        var j = 0
        for i in 0..<512 {
            if i < j {
                let r = re[i], m = im[i]
                re[i] = re[j]
                im[i] = im[j]
                re[j] = r
                im[j] = m
            }
            var bit = 0x100
            while bit != 0 && (j & bit) != 0 {
                j ^= bit
                bit >>= 1
            }
            j |= bit
        }

        var size = 2
        var shift = 1
        while size <= 512 {
            let half = size >> 1
            let step = 8192 >> shift
            var start = 0
            while start < 512 {
                for k in 0..<half {
                    let c = cosine[k * step]
                    let s = cosine[(6144 + k * step) & 8191]
                    let top = start + k
                    let bottom = start + half + k
                    let xr = re[bottom], xi = im[bottom]
                    // t = x e^-j(angle)
                    var tr = c * xr
                    tr = tr + s * xi
                    var ti = c * xi
                    ti = ti - s * xr
                    re[bottom] = re[top] - tr
                    im[bottom] = im[top] - ti
                    re[top] = tr + re[top]
                    im[top] = ti + im[top]
                }
                start += size
            }
            size <<= 1
            shift += 1
        }
    }
}
