//
//  HalfrateSynth.swift
//  DMRPilot
//
//  合成器：谐波振荡器、逆 FFT 噪声、脉冲、160 点重叠相加。
//  每帧从上一帧参数插值到当前帧参数。
//
//  移植自 DroidStar 的 mbe/decoder_synth.cc。相位累加全部使用 64 位定点，
//  依赖无符号溢出语义，所以 Swift 里必须用 &+ &- &* &<<。
//

import Foundation

// MARK: - 合成帧

struct HRSynthFrame {
    var active: Int32 = 0
    var fundamental: Float = 0
    var harmonicCount: Int32 = 0
    var amplitude = [Float](repeating: 0, count: HRCore.harmonicSlots)
    var voiced = [Float](repeating: 0, count: HRCore.harmonicSlots)
    var unvoiced = [Float](repeating: 0, count: HRCore.harmonicSlots)
    var pulse = [Float](repeating: 0, count: HRCore.harmonicSlots)
    var phase = [Float](repeating: 0, count: HRCore.harmonicSlots)
    var pulseCount: Int32 = 0
    var pulsePosition = [Int32](repeating: 0, count: 2)
    var pulseGain = [Float](repeating: 0, count: 2)
}

// MARK: - 合成状态

struct HRSynthState {
    var previous = HRSynthFrame()
    var harmonicPhase = [UInt64](repeating: 0, count: HRCore.harmonicSlots)
    var fundamentalPhase: UInt64 = 0
    var noisePhase = [UInt32](repeating: 0, count: 63)
    var overlap = [Float](repeating: 0, count: 2 * HRCore.frameSamples)
    var random: UInt32 = 0
    var window320 = [Float](repeating: 0, count: 320)
    var window80 = [Float](repeating: 0, count: 80)
}

// MARK: - 合成

enum HRSynth {

    private static let oneOver160: Float = 0.00625
    private static let oneOverTwoPi: Float = 0.15915494
    private static let logFloor: Float = 0.000001
    private static let ln2: Float = 0.69314718
    private static let log2e: Float = 1.4426950
    private static let whiteNoiseScale: Float = 0.273861289024353
    private static let sqrt3: Float = 1.7320508
    private static let flushBelow: Float = 1.0000000031710769e-30
    private static let seedOffset: UInt32 = 0x51c0_de01
    private static let samples = HRCore.frameSamples
    private static let slots = HRCore.harmonicSlots

    // MARK: 工具

    @inline(__always)
    private static func nextRandom(_ x: UInt32) -> UInt32 {
        x &* 1_664_525 &+ 1_013_904_223
    }

    @inline(__always)
    private static func clamp01(_ v: Float) -> Float {
        if !(v >= 0.0) { return 0.0 }
        return v > 1.0 ? 1.0 : v
    }

    @inline(__always)
    private static func toFixed64(_ x: Float, _ bits: Int) -> Int64 {
        HRCore.toInt64Sat(Double(x) * Double(UInt64(1) << UInt64(bits)))
    }

    /// 基频（周期/采样）转 32.32 定点相位增量，放在 64 位的高半部分
    @inline(__always)
    private static func phaseIncrement(_ fundamental: Float) -> UInt64 {
        UInt64(bitPattern: toFixed64(fundamental, 32)) &<< 32
    }

    /// 有符号 128 位乘积的高 64 位
    @inline(__always)
    private static func multiplyHigh(_ a: Int64, _ b: Int64) -> Int64 {
        a.multipliedFullWidth(by: b).high
    }

    // MARK: 噪声谱

    /// 一帧在 128 点 FFT 的 65 个 bin 上的噪声谱；幅度取自最近的谐波
    private static func noiseBins(options: HROptions, frame: HRSynthFrame) -> (amp: [Float], band: [Float]) {
        var amplitude = [Float](repeating: 0, count: 65)
        var band = [Float](repeating: 0, count: 65)
        if frame.active == 0 { return (amplitude, band) }

        let w0 = frame.fundamental
        let period = 1.0 / w0
        var gain = options.unvoicedGain
        gain = gain * HRCore.fastSqrt(32.0 / w0)

        for k in 0..<65 {
            var x = period * (Float(k) * (1.0 / 128.0))
            x = x + 0.5
            var l = Int(HRCore.toInt32Sat(x))
            amplitude[k] = 0
            band[k] = 0
            if l <= 0 {
                if options.unvoicedLowCut != 0 { continue }
                l = 1
            }
            if l > Int(frame.harmonicCount) { continue }
            var binGain: Float
            if k == 1 {
                binGain = options.noiseGainBin1
            } else if k <= 3 {
                binGain = options.noiseGainBins23
            } else {
                binGain = 1.0
            }
            amplitude[k] = gain * frame.amplitude[l] * binGain
            band[k] = frame.unvoiced[l]
        }
        return (amplitude, band)
    }

    /// 128 点正变换（核 e^-j，不缩放）
    private static func fft128(_ re: inout [Float], _ im: inout [Float]) {
        for i in 0..<128 {
            var j = 0
            for b in 0..<7 {
                j |= ((i >> b) & 1) << (6 - b)
            }
            if i < j {
                let a = re[i], b = im[i]
                re[i] = re[j]
                im[i] = im[j]
                re[j] = a
                im[j] = b
            }
        }
        var len = 2
        while len <= 128 {
            let half = len >> 1
            let step = 8192 / len
            var base = 0
            while base < 128 {
                for k in 0..<half {
                    let c = HRCore.cosAt(k * step)
                    let s = HRCore.cosAt((0x1800 + k * step) & 0x1fff)
                    let p = base + half + k
                    let q = base + k
                    let xr = re[p], xi = im[p]
                    var tr = c * xr
                    tr = tr + s * xi
                    var ti = c * xi
                    ti = ti - s * xr
                    re[p] = re[q] - tr
                    im[p] = im[q] - ti
                    re[q] = tr + re[q]
                    im[q] = ti + im[q]
                }
                base += len
            }
            len <<= 1
        }
    }

    /// 512 点 FFT 的 257 个 bin 上的谱
    private static func spectrumBins(frame: HRSynthFrame, weight: [Float], lowCut: Int32, top: Float) -> [Float] {
        var out = [Float](repeating: 0, count: 257)
        let period = 1.0 / frame.fundamental
        for k in 0..<257 {
            let h = period * (Float(k) * (1.0 / 512.0))
            let l = Int(HRCore.toInt32Sat(h + 0.5))
            var value: Float = 0
            if !(l <= 0 && lowCut != 0) {
                var m = l > 0 ? l : 1
                let count = Int(frame.harmonicCount)
                var inside = true
                if m > count {
                    inside = false
                    if top > 0.0 {
                        let fl = Float(count)
                        let limit = (fl + 0.5) + top * fl
                        if h < limit {
                            m = count
                            inside = true
                        }
                    }
                }
                if inside && m < weight.count {
                    value = frame.amplitude[m] * weight[m]
                }
            }
            out[k] = value
        }
        return out
    }

    /// 512 点逆变换，带 1/512 缩放
    private static func ifft512(_ re: inout [Float], _ im: inout [Float]) {
        for i in 0..<512 { im[i] = -im[i] }
        HRCore.fft512(&re, &im)
        for i in 0..<512 {
            re[i] = re[i] * (1.0 / 512.0)
            im[i] = im[i] * (-1.0 / 512.0)
        }
    }

    /// 滑音区间，空区间时退化为整帧
    private static func glideSpan(_ start: Int32, _ end: Int32) -> (from: Int32, to: Int32) {
        var s = start
        var e = end
        if s < 0 { s = 0 }
        if e >= Int32(samples) { e = Int32(samples) }
        if e > s { return (s, e) }
        return (0, Int32(samples))
    }

    // MARK: 谐波

    /// phase_tracking == 1：一条基频相位轨迹，第 l 次谐波为 l 倍加自身相位偏移
    private static func harmonicsTracked(
        state: inout HRSynthState,
        options: HROptions,
        frame: HRSynthFrame,
        out: inout [Float],
        count: Int,
        previousIncrement: UInt64
    ) {
        let prev = state.previous
        var currentIncrement = previousIncrement
        if frame.active != 0 { currentIncrement = phaseIncrement(frame.fundamental) }

        // 每采样的基频相位，其频率在两帧之间滑变
        var phase = [UInt64](repeating: 0, count: samples)
        var start: Int32 = 0
        var end: Int32 = 0
        let span = glideSpan(options.pitchGlideStart, options.pitchGlideEnd)
        start = span.from
        end = span.to

        let diff = currentIncrement &- previousIncrement
        let slope = Int64(bitPattern: diff) / Int64(end - start)
        let halfSlope = Int64(bitPattern: (UInt64(bitPattern: slope) &+ (UInt64(bitPattern: slope) >> 63)) >> 1)

        var acc = state.fundamentalPhase
        var freq = previousIncrement
        for n in 0..<samples {
            phase[n] = acc
            var step = freq &+ UInt64(bitPattern: halfSlope)
            var next = freq &+ UInt64(bitPattern: slope)
            if Int32(n) >= end {
                next = freq
                step = currentIncrement
            }
            if Int32(n) < start {
                step = previousIncrement
            } else {
                freq = next
            }
            acc = step &+ acc
        }
        state.fundamentalPhase = acc

        var l = 1
        while l <= count {
            let inPrev = prev.active != 0 ? l <= Int(prev.harmonicCount) : false
            let inCur = frame.active != 0 ? l <= Int(frame.harmonicCount) : false
            var ampPrev = inPrev ? prev.amplitude[l] : 0.0
            var ampCur = inCur ? frame.amplitude[l] : 0.0
            let voiPrev = inPrev ? prev.voiced[l] : 0.0
            let voiCur = inCur ? frame.voiced[l] : 0.0

            if voiPrev == 0.0 && voiCur == 0.0 {
                l += 1
                continue
            }

            let both = inPrev && inCur
            if both && options.amplitudeFrequencyMap != 0 && voiPrev > 0.0 && voiCur > 0.0 {
                // 上一帧在本帧第 l 次谐波频率处的幅度
                var x = Float(l)
                x = frame.fundamental * x
                x = x / prev.fundamental
                var i = Int(HRCore.toInt32Sat(x))
                var fraction = x - Float(HRCore.toInt32Sat(x))
                if i < 1 { fraction = 0.0 }
                i = i > 1 ? i : 1
                let prevCount = Int(prev.harmonicCount)
                let frac = i < prevCount ? fraction : 0.0
                i = i < prevCount ? i : prevCount
                if i < prev.amplitude.count {
                    ampPrev = prev.amplitude[i]
                    if frac > 0.0 && ampPrev > 0.0 && i + 1 < prev.amplitude.count && prev.amplitude[i + 1] > 0.0 {
                        let l0 = HRCore.fastLog2(ampPrev)
                        let l1 = HRCore.fastLog2(prev.amplitude[i + 1])
                        let l0b = HRCore.fastLog2(prev.amplitude[i])
                        var y = l1 - l0b
                        y = frac * y
                        y = l0 + y
                        ampPrev = HRCore.fastExp2(y)
                    }
                }
            }

            if !inPrev || (voiPrev == 0.0 && options.amplitudeHold != 0) { ampPrev = ampCur }
            if !inCur || (options.amplitudeHold != 0 && voiCur == 0.0) { ampCur = ampPrev }

            var lo: Float
            var hi: Float
            if !both {
                lo = options.harmonicFadeStart
                hi = options.harmonicFadeEnd
            } else if voiCur < voiPrev {
                lo = options.voicingOffStart
                hi = options.voicingOffEnd
            } else {
                lo = options.voicingOnStart
                hi = options.voicingOnEnd
            }

            var phaseCur = inCur ? frame.phase[l] : prev.phase[l]
            var phasePrev = phaseCur
            if inPrev { phasePrev = prev.phase[l] }
            let dphase = phaseCur - phasePrev
            let round: Float = dphase >= 0.0 ? 0.5 : -0.5

            let useLog = (ampCur > 0.0 && ampPrev > 0.0) && options.amplitudeLogInterp != 0
            let ampSpan = glideSpan(options.amplitudeGlideStart, options.amplitudeGlideEnd)
            let ampStart = ampSpan.from
            let ampEnd = ampSpan.to

            var ratio: Float
            var ampSlope: Float
            if useLog {
                let lc = HRCore.fastLog2(ampCur)
                let lp = HRCore.fastLog2(ampPrev)
                var y = lc - lp
                let r = 1.0 / Float(ampEnd - ampStart)
                y = r * y
                ratio = HRCore.fastExp2(y)
                ampSlope = 0.0
            } else {
                let d = ampCur - ampPrev
                let r = 1.0 / Float(ampEnd - ampStart)
                ampSlope = d * r
                ratio = 1.0
            }

            let phaseWrap = dphase - Float(HRCore.toInt32Sat(dphase + round))
            let voicingSpan = hi - lo
            let dvoicing = voiCur - voiPrev
            var amp = ampPrev

            for n in 0..<samples {
                if Int32(n) < ampStart || Int32(n) >= ampEnd {
                    amp = Int32(n) < ampEnd ? amp : ampCur
                } else if useLog {
                    amp = ratio * amp
                } else {
                    amp = ampPrev + ampSlope * Float(Int32(n) - ampStart + 1)
                }

                var t = Float(UInt32(n + 1))
                var phi = t * oneOver160
                phi = phaseWrap * phi
                phi = phasePrev + phi

                var v = t - lo
                v = v / voicingSpan
                v = clamp01(v)
                v = dvoicing * v
                v = voiPrev + v

                var x = phase[n] &* UInt64(l)
                let offset = toFixed64(phi, 32)
                v = v * amp
                x = x &+ (UInt64(bitPattern: offset) &<< 32)
                x = x &+ (1 &<< 50)
                x >>= 51
                v = v * HRCore.cosAt(Int(x))
                out[n] = out[n] + v
            }

            l += 1
        }
    }

    /// 其他 phase_tracking：每条谐波一个相位累加器，频率线性滑变
    private static func harmonicsAccumulated(
        state: inout HRSynthState,
        options: HROptions,
        frame: HRSynthFrame,
        out: inout [Float],
        count: Int,
        previousIncrement: UInt64
    ) {
        let prev = state.previous
        let curActive = frame.active
        var currentIncrement = previousIncrement
        if curActive != 0 { currentIncrement = phaseIncrement(frame.fundamental) }

        let curCount = Int(frame.harmonicCount)
        let prevCount = Int(prev.harmonicCount)
        let prevActive = prev.active

        var l = 1
        while l <= count {
            let absentPrev = !(prevActive != 0 && l <= prevCount)
            let absentCur = !(curActive != 0 && l <= curCount)

            var ampPrev: Float = 0
            var ampCur: Float = 0
            if !absentPrev { ampPrev = prev.amplitude[l] * prev.voiced[l] }
            if !absentCur { ampCur = frame.amplitude[l] * frame.voiced[l] }

            let freqCur = currentIncrement &* UInt64(l)
            var acc = state.harmonicPhase[l]
            var freqPrev = previousIncrement &* UInt64(l)
            if absentPrev { freqPrev = freqCur }

            var delta = Int64(bitPattern: freqCur &- freqPrev)
            if absentCur { delta = 0 }

            // delta / 160 与 delta / 320，向零截断
            let h = multiplyHigh(delta, 0x6666_6666_6666_6667)
            let step = (h >> 6) &+ Int64(bitPattern: UInt64(bitPattern: h) >> 63)

            if ampPrev == 0.0 && ampCur == 0.0 {
                acc = UInt64(bitPattern: step) &* 12800 &+ freqPrev &* 160 &+ acc
                state.harmonicPhase[l] = acc
                l += 1
                continue
            }

            var fade = false
            if ampPrev != 0.0 && ampCur == 0.0 {
                fade = l > curCount ? false : (curActive != 0)
            }

            let freqBase = (h >> 7) &+ Int64(bitPattern: UInt64(bitPattern: h) >> 63)
            var freq = UInt64(bitPattern: freqBase) &+ freqPrev

            var damp = ampCur - ampPrev
            damp = damp * oneOver160

            for n in 0..<samples {
                var a: Float
                let fadeEnd = options.voicedFadeEnd
                let fadeStart = options.voicedFadeStart
                if fade && fadeEnd > fadeStart {
                    var x = Float(UInt32(n)) - fadeStart
                    let y = fadeEnd - fadeStart
                    x = x / y
                    x = clamp01(x)
                    x = x * 0.5
                    x = HRCore.cosineInterpolated(x)
                    x = x * 0.5
                    x = x + 0.5
                    a = ampPrev * x
                } else {
                    a = damp * Float(UInt32(n + 1))
                    a = ampPrev + a
                }
                a = a * HRCore.cosAt(Int((acc &+ (1 &<< 50)) >> 51))
                out[n] = out[n] + a
                acc = freq &+ acc
                freq = freq &+ UInt64(bitPattern: step)
            }
            state.harmonicPhase[l] = acc
            l += 1
        }
    }

    // MARK: 噪声

    /// noise_method 1：4 个 40 采样块，128 点 FFT，80 采样正弦窗，重叠相加
    private static func noiseBlocks(
        state: inout HRSynthState,
        options: HROptions,
        frame: HRSynthFrame,
        out: inout [Float]
    ) {
        let previousBins = noiseBins(options: options, frame: state.previous)
        let currentBins = noiseBins(options: options, frame: frame)
        var amp0 = previousBins.amp
        var amp1 = currentBins.amp
        let band0 = previousBins.band
        let band1 = currentBins.band
        var log0 = [Float](repeating: 0, count: 65)
        var log1 = [Float](repeating: 0, count: 65)

        var none = true
        for k in 0..<65 {
            if band0[k] == 0.0 && band1[k] == 0.0 { continue }
            var x = amp0[k]
            var y = amp1[k]
            if x == 0.0 { amp0[k] = y; x = y }
            if y == 0.0 { amp1[k] = x; y = x }
            log0[k] = x > 0.0 ? HRCore.fastLog2(x) : 0.0
            log1[k] = y > 0.0 ? HRCore.fastLog2(y) : 0.0
            none = false
        }
        if none { return }

        var whiteRe = [Float](repeating: 0, count: 128)
        var whiteIm = [Float](repeating: 0, count: 128)
        var re = [Float](repeating: 0, count: 128)
        var im = [Float](repeating: 0, count: 128)

        for block in 0..<4 {
            let pos = Float(UInt32(40 * block + 40))
            let x = (pos - options.voicingOffStart) / (options.voicingOffEnd - options.voicingOffStart)
            let y = (pos - options.voicingOnStart) / (options.voicingOnEnd - options.voicingOnStart)
            let fall = clamp01(x)
            let rise = clamp01(y)

            if options.noiseWhite != 0 {
                for n in 0..<128 { whiteIm[n] = 0.0 }
                for n in 0..<128 {
                    var v: Float = 0.0
                    if n < 80 {
                        state.random = nextRandom(state.random)
                        v = Float(state.random >> 8) * (1.0 / 8388608.0)
                        v = v + -1.0
                        v = state.window80[n] * v
                    }
                    whiteRe[n] = v
                }
                fft128(&whiteRe, &whiteIm)
            }

            let framePos = pos * oneOver160
            for n in 0..<128 {
                re[n] = 0.0
                im[n] = 0.0
            }

            for k in 0..<63 {
                state.random = nextRandom(state.random)
                var ph = state.random >> 19
                if Int64(k + 1) < Int64(options.noiseCoherentBins) {
                    var jitter = Float(Int32(truncatingIfNeeded: ph &- 4096))
                    jitter = options.noisePhaseJitter * jitter
                    let ji = HRCore.toInt32Sat(jitter)
                    var v = UInt32(truncatingIfNeeded: 0xa00 * (k + 1)) &+ state.noisePhase[k]
                    v = v &+ UInt32(bitPattern: ji)
                    ph = v & 0x1fff
                    state.noisePhase[k] = ph
                }

                let bp = band0[k + 1]
                if bp == 0.0 && band1[k + 1] == 0.0 { continue }

                let x0 = amp0[k + 1]
                let x1 = amp1[k + 1]
                var m: Float
                if x0 > 0.0 && x1 > 0.0 && options.amplitudeLogInterp != 0 {
                    var d = log1[k + 1] - log0[k + 1]
                    d = framePos * d
                    m = HRCore.fastExp2(log0[k + 1] + d)
                } else {
                    var d = x1 - x0
                    d = framePos * d
                    m = x0 + d
                }

                let bc = band1[k + 1]
                let d = bc - bp
                let g0 = bc > bp ? fall : rise
                var g = d * g0
                g = bp + g
                g = m * g
                if g == 0.0 { continue }

                var vr: Float
                var vi: Float
                if options.noiseWhite != 0 {
                    vr = g * whiteRe[k + 1]
                    vr = vr * whiteNoiseScale
                    vi = g * whiteIm[k + 1]
                    vi = vi * whiteNoiseScale
                } else {
                    vr = g * HRCore.cosAt(Int(ph))
                    vi = g * HRCore.cosAt(Int((ph &+ 0x1800) & 0x1fff))
                }
                re[k + 1] = vr
                im[k + 1] = vi
                re[127 - k] = vr
                im[127 - k] = -vi
            }

            for n in 0..<128 { im[n] = -im[n] }
            fft128(&re, &im)

            for n in 0..<80 {
                var w: Float = 1.0
                if options.noiseWhite == 0 { w = state.window80[n] }
                var v = re[n] * (1.0 / 128.0)
                v = v * w
                let idx = 40 * block + n
                if idx <= 159 {
                    out[idx] = v + out[idx]
                } else {
                    state.overlap[idx - 160] = v + state.overlap[idx - 160]
                }
            }
        }
    }

    /// noise_method 0：一次 512 点 FFT，320 采样窗，在 noise_offset 处相加
    private static func noiseSingle(
        state: inout HRSynthState,
        options: HROptions,
        frame: HRSynthFrame,
        out: inout [Float]
    ) {
        var noise = [Float](repeating: 0, count: 320)
        var re = [Float](repeating: 0, count: 512)
        var im = [Float](repeating: 0, count: 512)

        var gain = options.unvoicedGain
        gain = gain * HRCore.fastSqrt(128.0 / frame.fundamental)
        let offset = Int(options.noiseOffset)
        let bins = spectrumBins(
            frame: frame,
            weight: frame.unvoiced,
            lowCut: options.unvoicedLowCut,
            top: options.unvoicedTopExtend
        )

        var any = false
        for k in 0..<257 where bins[k] != 0.0 {
            any = true
            break
        }

        if !any {
            for n in 0..<320 { noise[n] = 0.0 }
        } else {
            var r = state.random
            for k in 0..<257 {
                r = nextRandom(r)
                if (k & 0xff) == 0 {
                    re[k] = 0.0
                    im[k] = 0.0
                    continue
                }
                let a = gain * bins[k]
                let c = a * HRCore.cosAt(Int(r >> 19))
                re[k] = c
                let s = HRCore.cosAt(Int(((r >> 19) &+ 0x1800) & 0x1fff))
                im[k] = a * s
                re[512 - k] = c
                im[512 - k] = -(a * s)
            }
            state.random = r
            ifft512(&re, &im)
            for n in 0..<320 { noise[n] = re[n] * state.window320[n] }
        }

        for j in 0..<320 {
            let idx = offset + j
            if idx <= 159 {
                out[idx] = out[idx] + noise[j]
            } else if idx - 160 < state.overlap.count {
                state.overlap[idx - 160] = state.overlap[idx - 160] + noise[j]
            }
        }
    }

    // MARK: 脉冲

    private static func addPulses(
        state: inout HRSynthState,
        options: HROptions,
        frame: HRSynthFrame,
        out: inout [Float]
    ) {
        var re = [Float](repeating: 0, count: 512)
        var im = [Float](repeating: 0, count: 512)
        var pulse = [Float](repeating: 0, count: 512)

        var gain = options.pulseGain
        gain = gain * HRCore.fastSqrt(40.0 / frame.fundamental)
        var weights = spectrumBins(
            frame: frame,
            weight: frame.pulse,
            lowCut: 0,
            top: options.unvoicedTopExtend
        )

        for k in 0..<257 {
            let f = Float(k) * 15.625
            if !(f < options.pulseHighpassHz) { break }
            weights[k] = 0.0
        }

        if options.pulseMinimumPhase != 0 {
            // log 幅度的倒谱，折叠成因果，再变回谱并取指数
            for k in 0..<257 {
                let x = HRCore.maxNum(gain * weights[k], logFloor)
                let v = HRCore.fastLog2(x) * ln2
                re[k] = v
                im[k] = 0.0
                if (k & 0xff) != 0 {
                    re[512 - k] = v
                    im[512 - k] = 0.0
                }
            }
            ifft512(&re, &im)
            for k in 1..<256 {
                re[k] = re[k] + re[k]
                re[512 - k] = 0.0
            }
            for k in 0..<512 { im[k] = 0.0 }
            HRCore.fft512(&re, &im)
            for k in 0..<512 {
                let m = HRCore.fastExp2(re[k] * log2e)
                var p = im[k] * oneOverTwoPi
                re[k] = m * HRCore.cosineInterpolated(p)
                p = p + -0.25
                im[k] = m * HRCore.cosineInterpolated(p)
            }
            ifft512(&re, &im)
            for n in 0..<256 { pulse[n] = 0.0 }
            for n in 0..<256 { pulse[256 + n] = re[n] }
        } else {
            for k in 0..<257 {
                var x = gain * weights[k]
                if k == 256 { x = 0.0 }
                re[k] = x
                im[k] = 0.0
                if (k & 0xff) != 0 {
                    re[512 - k] = x
                    im[512 - k] = 0.0
                }
            }
            ifft512(&re, &im)
            for n in 0..<512 { pulse[n] = re[n ^ 0x100] }
        }

        let length = options.pulseLength
        for n in 0..<512 {
            let d0 = Float(n - 256)
            let d: Float = n < 256 ? -d0 : d0
            var v: Float = 0.0
            if !(d > length) {
                v = pulse[n]
                var x = d * 0.5
                if d != 0.0 { x = x / length }
                x = HRCore.cosineInterpolated(x)
                x = x * 0.5
                x = x + 0.5
                v = v * x
            }
            pulse[n] = v
        }

        var i: Int32 = 0
        while i < frame.pulseCount {
            var pos = Int(UInt32(bitPattern: options.pulseShift) &+ UInt32(bitPattern: frame.pulsePosition[Int(i)]))
            let pulseGain = frame.pulseGain[Int(i)]
            for j in 0..<512 {
                let v = pulse[j]
                if v != 0.0 && pos >= 256 {
                    if pos < 256 + samples {
                        out[pos - 256] = pulseGain * v + out[pos - 256]
                    } else if pos < 256 + 3 * samples {
                        let index = pos - 416
                        if index < state.overlap.count {
                            state.overlap[index] = pulseGain * v + state.overlap[index]
                        }
                    }
                }
                pos += 1
            }
            i += 1
        }
    }

    // MARK: 对外接口

    static func reset(_ state: inout HRSynthState, options: HROptions) {
        state = HRSynthState()
        var r = UInt32(bitPattern: options.noiseSeed) &+ seedOffset
        state.random = r

        for i in 0..<320 {
            var x = Float(UInt32(i)) + 0.5
            x = x / 640.0
            x = x + -0.25
            state.window320[i] = HRCore.cosineInterpolated(x)
        }
        for i in 0..<80 {
            var x = Float(UInt32(i)) + 0.5
            x = x / 160.0
            x = x + -0.25
            state.window80[i] = HRCore.cosineInterpolated(x)
        }

        var q: UInt32 = 0
        for j in 0..<slots {
            var v: UInt64
            if options.initialPhase == 2 {
                v = UInt64(q &* UInt32(j)) &<< 32
            } else if options.initialPhase == 1 {
                r = nextRandom(r)
                state.random = r
                v = UInt64(r) &<< 32
            } else {
                v = 0
            }
            state.harmonicPhase[j] = v
            q = q &+ 0x0900_0000
        }
    }

    static func comfortNoise(_ state: inout HRSynthState, level: Float, out: inout [Float]) {
        var r = state.random
        for i in 0..<samples {
            r = nextRandom(r)
            var u = Float(r >> 8) * (1.0 / 8388608.0)
            u = u + -1.0
            out[i] = level * u * sqrt3
        }
        state.random = r
    }

    static func synthFrame(
        _ state: inout HRSynthState,
        options: HROptions,
        frame: HRSynthFrame,
        out: inout [Float]
    ) {
        for n in 0..<samples { out[n] = state.overlap[n] }
        for n in 0..<samples {
            state.overlap[n] = state.overlap[samples + n]
            state.overlap[samples + n] = 0.0
        }

        if frame.active == 0 && state.previous.active == 0 {
            state.previous = frame
            return
        }

        let lc = Int(frame.harmonicCount)
        let lp = Int(state.previous.harmonicCount)
        let count = lc > lp ? lc : lp
        let pitchFrom = state.previous.active == 0 ? frame : state.previous
        let previousIncrement = phaseIncrement(pitchFrom.fundamental)

        if options.phaseTracking == 1 {
            harmonicsTracked(
                state: &state, options: options, frame: frame,
                out: &out, count: count, previousIncrement: previousIncrement
            )
        } else if count >= 1 {
            harmonicsAccumulated(
                state: &state, options: options, frame: frame,
                out: &out, count: count, previousIncrement: previousIncrement
            )
        }

        if options.noiseMethod == 1 {
            noiseBlocks(state: &state, options: options, frame: frame, out: &out)
        }

        if frame.active != 0 {
            if options.noiseMethod == 0 {
                noiseSingle(state: &state, options: options, frame: frame, out: &out)
            }
            if frame.pulseCount >= 1 {
                addPulses(state: &state, options: options, frame: frame, out: &out)
            }
        }

        for n in 0..<samples {
            if abs(out[n]) < flushBelow { out[n] = 0.0 }
        }
        state.previous = frame
    }
}
