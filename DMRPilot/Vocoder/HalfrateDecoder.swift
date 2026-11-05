//
//  HalfrateDecoder.swift
//  DMRPilot
//
//  帧解码器：语音帧、静音帧、单音帧、丢帧隐藏（重复 / 静音 / 舒适噪声），
//  以及输出级（高通、帧限幅、软限幅、转 16 位）。
//
//  移植自 DroidStar 的 mbe/decoder.cc、mbe/enhance.cc、mbe/decoder_api.cc。
//

import Foundation

enum HRDecodedKind: Int32 {
    case voice = 0
    case silence = 1
    case tone = 2
    case erasure = 3
}

struct HRHighPassSection {
    var x1: Float = 0
    var x2: Float = 0
    var y1: Float = 0
    var y2: Float = 0
}

struct HRHighPass {
    var cutoff: Float = -1
    var b0: Float = 0
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0
    var sections = [HRHighPassSection](repeating: HRHighPassSection(), count: 2)
}

// MARK: - 解码器

final class HRDecoder {

    private static let oneOverTwoPi: Float = 0.15915493667125702
    private static let oneOver160: Float = 0.0062500000931322575
    private static let sqrtHalf: Float = 0.7071067690849304
    private static let sqrt2: Float = 1.4142135381698608
    private static let dbPerLog2: Float = 3.0102999210357666
    private static let log2PerDb: Float = 0.16609640419483185
    private static let limiterCeiling: Float = 32766.0
    private static let flushBelow: Float = 1.0000000031710769e-30
    private static let toneLevelLog2: Float = 0.11800000071525574
    private static let toneScale: Float = 2737.0
    private static let sampleRate: Float = 8000.0
    private static let dialTone425: Float = 425.0

    private static let firstNonVoicePitch = 120
    private static let silencePitch: Int32 = 124
    private static let silenceVoicing: Int32 = 16
    private static let firstPulseVoicing: Int32 = 18
    private static let pulsePairVoicing: Int32 = 24

    private static let singleToneFirst: UInt32 = 5
    private static let singleToneLast: UInt32 = 122
    private static let keypadTones: UInt32 = 0x80
    private static let toneSet: UInt32 = 0x90
    private static let progress350_440: UInt32 = 0xa0
    private static let tone425: UInt32 = 0xa1
    private static let progress480_620: UInt32 = 0xa2
    private static let progress350_490: UInt32 = 0xa3

    private static let samples = HRCore.frameSamples

    var options = HROptions()

    private var dequant = HRDequantState()
    private var synth = HRSynthState()
    private var lastGood = HRSynthFrame()
    private var hadGood = false
    private var badCount: Int32 = 0
    private var muted = false
    private var tonePhase: [UInt32] = [0, 0]
    private var limiterGain: Float = 1.0
    private var highpass = HRHighPass()

    init() {
        reset()
    }

    func reset() {
        HRDequant.reset(&dequant)
        HRSynth.reset(&synth, options: options)
        lastGood = HRSynthFrame()
        hadGood = false
        badCount = 0
        muted = false
        tonePhase = [0, 0]
        limiterGain = 1.0
        highpass = HRHighPass()
    }

    // MARK: - 9 字节空口帧

    /// 解一个 DMR 空口帧（9 字节，含 FEC 与交织），输出 160 个 8 kHz 采样
    @discardableResult
    func decodeAir(_ air: [UInt8], pcm: inout [Int16]) -> HRDecodedKind {
        let result = HRFec.decodeAirFrame(air)
        return decode(bits: result.bits, pcm: &pcm)
    }

    /// 丢帧（没有收到帧）
    func decodeErased(pcm: inout [Int16]) {
        var buf = [Float](repeating: 0, count: Self.samples)
        conceal(&buf)
        output(&buf, pcm: &pcm)
    }

    // MARK: - 主解码

    @discardableResult
    func decode(bits input: [UInt8], pcm: inout [Int16]) -> HRDecodedKind {
        let bits = options.rotatedLayout == 1 ? HRFrame.standardFromRotated(input) : input
        let received = HRFrame.fieldsFromBits(bits)
        var buf = [Float](repeating: 0, count: Self.samples)
        var params = HRFrameParams()
        var kind = HRDecodedKind.voice

        let pitch = Int(received[HRField.pitch])

        if pitch < Self.firstNonVoicePitch {
            // 语音帧。脉冲帧可以用固定音高索引反量化，收到的音高只用来定位脉冲
            var fields = received
            if received[HRField.voicing] >= Self.firstPulseVoicing && options.pulsePitchIndex >= 0 {
                fields[HRField.pitch] = options.pulsePitchIndex
                params = HRDequant.dequantize(&dequant, fields).1
                params.fields[HRField.pitch] = received[HRField.pitch]
            } else {
                params = HRDequant.dequantize(&dequant, fields).1
            }
            voice(params, silence: false, buf: &buf)
            kind = .voice
        } else if (received[HRField.voicing] & ~1) == Self.silenceVoicing {
            // 静音帧：用固定音高反量化，silence_predictor 决定对预测器的影响
            var fields = received
            fields[HRField.pitch] = Self.silencePitch
            let mode = options.silencePredictor
            if mode == 2 || mode == 3 {
                let saved = dequant
                if mode == 2 { HRDequant.reset(&dequant) }
                params = HRDequant.dequantize(&dequant, fields).1
                dequant = saved
            } else {
                if mode == 1 { HRDequant.reset(&dequant) }
                params = HRDequant.dequantize(&dequant, fields).1
                if mode == 4 || mode == 1 { HRDequant.reset(&dequant) }
            }
            params.fields[HRField.voicing] = Self.silenceVoicing
            voice(params, silence: true, buf: &buf)
            kind = .silence
        } else {
            // 单音帧的字段直接从收到的比特读，不做布局旋转
            kind = toneOrErasure(input, buf: &buf)
        }

        output(&buf, pcm: &pcm)
        return kind
    }

    // MARK: - 丢帧隐藏

    private func conceal(_ buf: inout [Float]) {
        let n = badCount
        badCount = n + 1

        if hadGood {
            if n >= options.repeatMax {
                if !muted {
                    let silent = HRSynthFrame()
                    HRSynth.synthFrame(&synth, options: options, frame: silent, out: &buf)
                    muted = true
                    return
                }
            } else if !muted {
                var p = lastGood
                let count = Int(p.harmonicCount)
                let gain = options.repeatGain
                let start = options.repeatHighStart
                let span = (0.5 - start) > 0.01 ? (0.5 - start) : 0.01
                let liftBase = options.repeatHighGain > 0.0 ? options.repeatHighGain : 1.0
                let lift = log(Double(liftBase))
                for k in 0..<count {
                    let f = Float(k + 1) * p.fundamental
                    var scale = gain
                    if f > start && lift != 0.0 {
                        scale = gain * Float(exp(lift * Double(f - start) / Double(span)))
                    }
                    p.amplitude[1 + k] = p.amplitude[1 + k] * scale
                }
                lastGood = p
                HRSynth.synthFrame(&synth, options: options, frame: p, out: &buf)
                return
            }
        }

        HRSynth.comfortNoise(&synth, level: options.comfortNoiseLevel, out: &buf)
        synth.previous = HRSynthFrame()
        muted = true
    }

    // MARK: - 单音 / 丢帧

    private func toneOrErasure(_ input: [UInt8], buf: inout [Float]) -> HRDecodedKind {
        for k in 0..<8 where input[k] == 0 {
            conceal(&buf)
            return .erasure
        }

        var copies = [Int32](repeating: 0, count: 4)
        for j in 0..<4 {
            var v: UInt32 = 0
            for k in 0..<8 {
                v = UInt32(input[12 + 8 * j + k]) | (v << 1)
            }
            copies[j] = Int32(bitPattern: v)
        }
        if !(copies[0] == copies[1] && copies[0] == copies[2] && copies[0] == copies[3]) {
            conceal(&buf)
            return .erasure
        }

        let index = UInt32(bitPattern: copies[0])
        var level = UInt32(input[9]) << 3 | UInt32(input[8]) << 4
        level |= UInt32(input[10]) << 2
        level |= UInt32(input[11]) << 1
        level |= UInt32(input[44])

        badCount = 0
        muted = false

        var silent: Bool
        var dual: Bool
        var freqA: Float
        var freqB: Float

        if (index &- Self.singleToneFirst) <= (Self.singleToneLast &- Self.singleToneFirst) {
            silent = false
            dual = false
            freqA = Float(index) * 31.25
            freqB = 0.0
        } else if (index & ~0xf) == Self.toneSet {
            silent = false
            let pick = index - Self.toneSet
            let lowIndex = Int(HRTables.toneSetIndex[Int(pick) * 2])
            let highIndex = Int(HRTables.toneSetIndex[Int(pick) * 2 + 1])
            freqA = HRTables.toneSetLow[lowIndex]
            freqB = HRTables.toneSetHigh[highIndex]
            dual = true
        } else if (index & ~0xf) == Self.keypadTones {
            silent = false
            let i = Int(index - Self.keypadTones)
            freqA = HRTables.keypadLow[Int(HRTables.keypadLowIndex[i])]
            freqB = HRTables.keypadHigh[Int(HRTables.keypadHighIndex[i])]
            dual = true
        } else {
            dual = false
            silent = true
            freqA = 0.0
            freqB = 0.0
            if index == Self.progress480_620 {
                silent = false; dual = true; freqA = 480.0; freqB = 620.0
            } else if index == Self.progress350_490 {
                silent = false; dual = true; freqA = 350.0; freqB = 490.0
            } else if index == Self.progress350_440 {
                silent = false; dual = true; freqA = 350.0; freqB = 440.0
            } else if index == Self.tone425 {
                silent = false; freqA = Self.dialTone425
            }
        }

        let scale = options.toneGain
        var a = HRCore.fastExp2(Float(level) * Self.toneLevelLog2)

        if silent {
            for i in 0..<Self.samples { buf[i] = 0.0 }
        } else {
            let s = scale * Self.toneScale
            a = s * a
            let single = a * Self.sqrt2
            let inc1 = HRCore.toInt64Sat(Double(freqA / Self.sampleRate) * 4_294_967_296.0)
            let inc2 = HRCore.toInt64Sat(Double(freqB / Self.sampleRate) * 4_294_967_296.0)
            if index == Self.tone425 { a = single }

            var ph1 = tonePhase[0]
            var ph2 = tonePhase[1]
            for i in 0..<Self.samples {
                var v = HRCore.cosAt(Int((ph1 &+ 0x4_0000) >> 19))
                if dual { v = v + HRCore.cosAt(Int((ph2 &+ 0x4_0000) >> 19)) }
                buf[i] = a * v
                ph1 = ph1 &+ UInt32(bitPattern: Int32(truncatingIfNeeded: inc1))
                ph2 = ph2 &+ UInt32(bitPattern: Int32(truncatingIfNeeded: inc2))
            }
            tonePhase[1] = ph2
            tonePhase[0] = ph1
        }

        HRDequant.reset(&dequant)
        HRSynth.reset(&synth, options: options)
        hadGood = false
        return .tone
    }

    // MARK: - 语音帧

    private func voice(_ params: HRFrameParams, silence: Bool, buf: inout [Float]) {
        let o = options
        let voicing = params.fields[HRField.voicing]
        let pitch = params.fields[HRField.pitch]
        let voicedShare = HRCore.fastSqrt(o.mixedVoicedShare)
        let noiseShare = HRCore.fastSqrt(1.0 - o.mixedVoicedShare)

        var p = HRSynthFrame()
        var phase = [Float](repeating: 0, count: HRCore.harmonicSlots)
        var amp = [Float](repeating: 0, count: Self.samples)

        p.active = 1
        p.fundamental = params.fundamental
        var count = Int(params.harmonicCount)
        p.harmonicCount = params.harmonicCount
        let decodedCount = count
        let log2Amp = params.log2Amplitude

        if decodedCount >= 1 {
            for k in 0..<count {
                amp[1 + k] = HRCore.fastExp2(log2Amp[k])
            }
            // 每个谐波的相位项：其附近对数幅度差的加权和
            let taps = Int(o.phaseTaps)
            let dispersion = o.phaseDispersion
            for l in 1...count {
                let l1 = l - 1
                var sum: Float = 0
                if taps >= 1 {
                    var m = 0
                    var nm = 0
                    let step = o.phaseOddTaps != 0 ? 2 : 1
                    repeat {
                        var up: Float = 0
                        if count >= l1 + m + 2 {
                            up = log2Amp[l1 + m + 1] + o.phaseLevelOffset
                        }
                        var lo: Float
                        if l1 + nm >= 1 {
                            lo = log2Amp[l1 + nm - 1] + o.phaseLevelOffset
                        } else {
                            lo = 0
                        }
                        up = up - lo
                        up = up * HRTables.phaseTapWeight[m + 1]
                        sum = sum + up
                        m += step
                        nm -= step
                    } while m + 1 <= taps
                }
                sum = dispersion * sum
                sum = sum * Self.oneOverTwoPi
                phase[l] = sum
            }
        }

        enhanceFormants(o.enhanceOptions, fundamental: params.fundamental, omega: params.omega,
                        harmonicCount: count, amplitude: &amp)
        count = Int(params.harmonicCount)

        var weightsDone = false
        if o.highBandTilt != 0.0 {
            if count < 1 {
                weightsDone = true
            } else {
                var l = 1
                while true {
                    var t = Float(UInt32(l)) / Float(count)
                    let start = o.highBandStart
                    t = t - start
                    let width = 1.0 - start
                    t = t / width
                    if t > 0.0 {
                        let a = amp[l]
                        t = t > 1.0 ? 1.0 : t
                        t = t * o.highBandTilt
                        amp[l] = a * HRCore.fastExp2(t)
                    }
                    if !(l < count) { break }
                    l += 1
                }
            }
        }

        if !weightsDone && count >= 1 {
            let row = silence ? 16 : Int(voicing & 0x1f)
            let classesBase = row * 16
            let w0 = params.fundamental
            let gain = o.outputGain

            for k in 0..<count {
                let x = w0 * Float(UInt32(k + 1))
                var slot = HRCore.toInt32Sat(Double(x) * 32.0)
                slot = slot < 15 ? slot : 15
                let cls = HRTables.harmonicClass[classesBase + Int(slot)]

                p.amplitude[1 + k] = amp[1 + k] * gain
                var weight: Float = 1.0
                var target = 1  // 0 = voiced, 1 = unvoiced, 2 = pulse

                switch cls {
                case 4: // PulseNoise
                    if o.pulseEnable != 0 {
                        p.pulse[1 + k] = o.pulseNoisePulseWeight
                        weight = o.pulseNoiseNoiseWeight
                    }
                case 0: // Voiced
                    weight = o.voicedWeight
                    target = 0
                case 2: // Mixed
                    p.voiced[1 + k] = voicedShare * o.voicedWeight
                    weight = noiseShare
                case 3: // Pulse
                    target = o.pulseEnable == 0 ? 1 : 2
                default:
                    break
                }

                switch target {
                case 0: p.voiced[1 + k] = weight
                case 2: p.pulse[1 + k] = weight
                default: p.unvoiced[1 + k] = weight
                }
            }
            for l in 1...count { p.phase[l] = phase[l] }
        }

        p.pulseCount = 0
        if !silence && voicing >= Self.firstPulseVoicing {
            if o.pulseEnable != 0 {
                let window = o.pulseWindow
                var distance: Float

                if (voicing & 0x7fff_fffe) == Self.pulsePairVoicing {
                    // 两个脉冲：位置由 pitch / 11 与 pitch % 11 决定
                    let q = pitch / 11
                    let r = pitch - q * 11
                    var s = o.pulsePairFirstStep * Float(q)
                    s = o.pulsePairFirstStart + s
                    s = s + 0.5
                    let pos = Int(HRCore.toInt32Sat(s))
                    var s2 = o.pulsePairSecondStep * Float(r)
                    s2 = o.pulsePairSecondStart + s2
                    s2 = s2 + 0.5
                    let pos2 = Int(HRCore.toInt32Sat(s2))

                    var d1 = Float(Int32(bitPattern: UInt32(bitPattern: Int32(pos)) &- 160))
                    d1 = pos < 160 ? -d1 : d1
                    let d2 = Float(Int32(bitPattern: UInt32(bitPattern: Int32(pos2)) &- 80))
                    d1 = d1 / window
                    d1 = 1.0 - d1
                    d1 = HRCore.maxNum(d1, 0.0)
                    p.pulseGain[0] = d1
                    p.pulsePosition[1] = Int32(pos2)
                    distance = pos2 < 80 ? -d2 : d2
                    p.pulseCount = 2
                    p.pulsePosition[0] = Int32(pos)
                } else {
                    let base = voicing < Self.pulsePairVoicing ? o.pulsePositionLow : o.pulsePositionHigh
                    p.pulsePosition[0] = base &+ pitch
                    let d = Float(pitch &- o.pulseWindowCenter)
                    let below = Int64(pitch) - Int64(o.pulseWindowCenter) < 0
                    distance = below ? -d : d
                    p.pulseCount = 1
                }

                var g = distance / window
                g = 1.0 - g
                g = HRCore.maxNum(g, 0.0)
                p.pulseGain[Int(p.pulseCount) - 1] = g
            }
        } else if silence && decodedCount >= 1 {
            let g = o.silenceGain
            for k in 0..<decodedCount {
                p.amplitude[1 + k] = p.amplitude[1 + k] * g
            }
        }

        badCount = 0
        muted = false
        HRSynth.synthFrame(&synth, options: options, frame: p, out: &buf)
        lastGood = p
        hadGood = true
    }

    // MARK: - 共振峰增强

    private func enhanceFormants(
        _ o: HREnhanceOptions,
        fundamental: Float,
        omega: Float,
        harmonicCount: Int,
        amplitude: inout [Float]
    ) {
        guard o.mode == 1 else { return }
        let count = harmonicCount
        if count < 1 { return }

        func harmonicCosine(_ harmonic: Float) -> Float {
            var phase = fundamental * harmonic
            phase = phase * 8192.0
            phase = phase + 0.5
            return HRCore.cosAt(Int(HRCore.toInt64Sat(Double(phase)) & 8191))
        }

        var r0: Float = 0
        var r1: Float = 0
        for l in 1...count {
            let power = amplitude[l] * amplitude[l]
            r0 = r0 + power
            r1 = r1 + power * harmonicCosine(Float(UInt32(l)))
        }
        if r0 <= 0.0 { return }

        let r0Squared = r0 * r0
        let r1Squared = r1 * r1
        let squares = r1Squared + r0Squared
        let twiceProduct = r1 * (r0 + r0)
        let difference = r0Squared - r1Squared

        var weight = [Float](repeating: 1.0, count: HRCore.maxHarmonics + 8)
        let every = o.bypassDivisor
        var bypassLimit = UInt32(bitPattern: every)

        for l in 1...count {
            defer { bypassLimit = bypassLimit &+ UInt32(bitPattern: every) }
            var w: Float = 1.0
            let denominator = difference * (r0 * omega)
            let harmonic = Float(UInt32(l))

            if denominator > 0.0 {
                var numerator = squares - twiceProduct * harmonicCosine(harmonic)
                numerator = numerator * 3.0159289836883545  // kResponseScale
                if numerator > 0.0 && amplitude[l] > 0.0 {
                    let log2Amplitude = HRCore.fastLog2(amplitude[l])
                    var log2Response = HRCore.fastLog2(numerator / denominator)
                    log2Response = log2Response * 0.5
                    let raw = HRCore.fastExp2(o.strength * (log2Amplitude + log2Response))
                    if every >= 1 && Int32(bitPattern: bypassLimit) <= Int32(count) {
                        w = 1.0
                    } else {
                        w = raw > o.maxWeight ? o.maxWeight : (raw < o.minWeight ? o.minWeight : raw)
                    }
                    let exponent = fundamental * harmonic < o.splitFrequency ? o.powerLow : o.powerHigh
                    if exponent != 1.0 {
                        w = HRCore.fastExp2(exponent * HRCore.fastLog2(w))
                    }
                }
            }
            weight[l] = w
        }

        var energy: Float = 0
        for l in 1...count {
            let v = amplitude[l] * weight[l]
            amplitude[l] = v
            energy = energy + v * v
        }
        var scale: Float = 1.0
        if energy > 0.0 { scale = HRCore.fastSqrt(r0 / energy) }
        for l in 1...count { amplitude[l] = scale * amplitude[l] }
    }

    // MARK: - 输出级

    private func output(_ buf: inout [Float], pcm: inout [Int16]) {
        let o = options

        // 高通（默认关闭）
        let fc = o.highpassHz
        if fc > 0.0 {
            if !(highpass.cutoff == fc) {
                var t = fc * 8192.0
                t = t / Self.sampleRate
                t = t + 0.5
                let i = HRCore.toInt32Sat(Double(t))
                let cosW = HRCore.cosAt(Int(UInt32(bitPattern: i) & 0x1fff))
                var alpha = HRCore.cosAt(Int((UInt32(bitPattern: i) &+ 0x1800) & 0x1fff))
                alpha = alpha * Self.sqrtHalf
                let a0 = alpha + 1.0
                let onePlusCos = cosW + 1.0
                highpass.b1 = -onePlusCos / a0
                var b0 = onePlusCos * 0.5
                var a1 = cosW * -2.0
                b0 = b0 / a0
                a1 = a1 / a0
                highpass.b0 = b0
                highpass.b2 = b0
                highpass.a1 = a1
                highpass.a2 = (1.0 - alpha) / a0
                highpass.cutoff = fc
            }

            for index in 0..<2 {
                var z = highpass.sections[index]
                for i in 0..<Self.samples {
                    let x = buf[i]
                    var y = x * highpass.b0
                    let p0 = highpass.b1 * z.x1
                    let p1 = highpass.b2 * z.x2
                    y = y + p0
                    y = y + p1
                    let q0 = highpass.a1 * z.y1
                    let q1 = highpass.a2 * z.y2
                    y = y - q0
                    y = y - q1
                    let oldX1 = z.x1
                    let oldY1 = z.y1
                    z.x1 = x
                    z.x2 = oldX1
                    z.y1 = abs(y) >= Self.flushBelow ? y : 0.0
                    z.y2 = abs(oldY1) >= Self.flushBelow ? oldY1 : 0.0
                    buf[i] = y
                }
                highpass.sections[index] = z
            }
        }

        // 帧限幅
        if o.frameLimiter != 0 {
            var energy: Float = 0
            for i in 0..<Self.samples {
                let q = buf[i] * buf[i]
                energy = energy + q
            }
            energy = energy * Self.oneOver160

            var db: Float = 0
            var g: Float = 1.0
            if energy > 1.0 { db = HRCore.fastLog2(energy) * Self.dbPerLog2 }
            let knee = o.frameLimiterKneeDb
            if db > knee {
                var t = db - knee
                t = t * o.frameLimiterRatio
                t = knee + t
                t = t - db
                t = t * Self.log2PerDb
                g = HRCore.fastExp2(t)
            }
            for i in 0..<Self.samples {
                var r = Float(UInt32(i + 1)) * Self.oneOver160
                let g0 = limiterGain
                let dg = g - g0
                r = r * dg
                r = g0 + r
                buf[i] = buf[i] * r
            }
            limiterGain = g
        }

        // 软限幅 + 转 16 位
        let threshold = o.limiterThreshold
        let on = !(threshold <= 0.0)
        let headroom = Self.limiterCeiling - threshold
        for i in 0..<Self.samples {
            var x = buf[i]
            let negative = x < 0.0
            let ax = negative ? -x : x
            if on && !(threshold >= ax) {
                var v = ax - threshold
                v = v / headroom
                let w = v * headroom
                v = v + 1.0
                v = w / v
                v = threshold + v
                x = negative ? -v : v
            }
            let high = x >= 32767.0
            let low = -32768.0 >= x
            if !high && !low {
                let h: Float = x >= 0.0 ? 0.5 : -0.5
                pcm[i] = Int16(truncatingIfNeeded: HRCore.toInt32Sat(Double(x + h)))
            } else {
                pcm[i] = (low && !high) ? -32768 : 32767
            }
        }
    }
}
