//
//  HalfrateEncoder.swift
//  DMRPilot
//
//  AMBE+2 半速率编码器（发送方向）：8 kHz / 160 采样 → 9 字节空口帧。
//
//  解码端（HalfrateDequant / HalfrateSynth）是逐行移植来的，编码端没有对应的参考实现
//  可以搬，所以这里做的是**分析 + 码本量化**：
//
//      16 位 PCM ──加窗/基音估计──▶ f0
//                 ──谐波 DFT──▶ 每个谐波的 log2 幅度
//                 ──谐波性判据──▶ 8 个频带的清浊
//                 ──预测 + 码本搜索──▶ 9 个参数字段 ──FEC──▶ 9 字节
//
//  关键点：量化必须和 `HRDequant.dequantize` 严格互逆，否则对端解出来的幅度是散的。
//  这里不自己发明反量化，而是**直接调用解码端的函数**来算候选误差——编码器的目标
//  就是「让解码端重建出我测量的这组幅度」，用同一份代码评判自然一致。
//
//  绝对电平：码本里的增益是归一化单位，不是 16 位满幅。硬编码一个偏移量风险太大
//  （不同实现的尺度差 20 dB 都正常），所以启动时用解码器做一次**探针标定**：
//  用已知参数解一帧、量出 RMS，就能得到「RMS → 平均 log2 幅度」的偏移。
//

import Foundation

final class HREncoder {

    // MARK: - 常量

    /// 浊音帧里可用的最大更浊索引（18 起是脉冲/双音模式，不能用在语音上）
    private static let maxVoicingIndex: Int = 17
    /// 分析带宽上限（相对采样率），再高的谐波直接丢掉
    private static let nyquistLimit: Float = 0.46
    /// 判定「这一帧几乎没有声音」的 RMS 门限
    private static let silenceRMS: Float = 24

    // MARK: - 状态

    private var window: [Float]
    private var windowSum: Float
    /// 与解码端同步推进的反量化状态（做谱形预测用）
    private var state = HRDequantState()
    /// 上一帧的音高索引，做迟滞，避免逐帧抖动听起来像颤音
    private var lastPitchIndex: Int = 40
    /// 探针标定结果：log2(RMS) 与参数平均 log2 幅度之间的偏移
    private static var levelBias: Float = -6
    private static var levelBiasDone = false

    init() {
        let n = HRCore.frameSamples
        var w = [Float](repeating: 0, count: n)
        var sum: Float = 0
        for i in 0..<n {
            let v = Float(0.54 - 0.46 * cos(2.0 * Double.pi * Double(i) / Double(n - 1)))
            w[i] = v
            sum += v
        }
        window = w
        windowSum = sum
    }

    func reset() {
        state = HRDequantState()
        lastPitchIndex = 40
    }

    // MARK: - 对外

    /// 一帧 PCM（160 采样）→ 9 字节空口帧
    func encode(_ pcm: [Int16]) -> [UInt8] {
        let fields = analyze(pcm)
        let bits = HRFrame.rotatedFromStandard(HRFrame.bitsFromFields(fields))
        return HRFec.encodeAirFrame(bits)
    }

    /// 连续三帧（60 ms）→ 27 字节，正好喂给 `DMRCallCodec.voiceBurst`
    func encodeBurst(_ frames: [[Int16]]) -> [UInt8] {
        var packed = [UInt8]()
        packed.reserveCapacity(27)
        for i in 0..<3 {
            let frame = i < frames.count ? frames[i] : [Int16](repeating: 0, count: HRCore.frameSamples)
            packed.append(contentsOf: encode(frame))
        }
        return packed
    }

    // MARK: - 分析

    private func analyze(_ pcm: [Int16]) -> [Int32] {
        HREncoder.calibrateIfNeeded()

        let n = HRCore.frameSamples
        var x = [Float](repeating: 0, count: n)
        // 短帧按静音补零（采集被中断时会出现），直接按下标取会崩
        let available = min(pcm.count, n)
        var mean: Float = 0
        for i in 0..<available { mean += Float(pcm[i]) }
        mean /= Float(n)
        var power: Float = 0
        for i in 0..<available {
            let v = Float(pcm[i]) - mean
            x[i] = v
            power += v * v
        }
        let rms = Float(sqrt(Double(power / Float(n))))

        // 1. 基音
        let pitchIndex = nearestPitch(estimateFundamental(x))
        lastPitchIndex = pitchIndex
        let fundamental = HRTables.pitchFundamental[pitchIndex]
        var count = Int(HRTables.pitchHarmonicCount[pitchIndex])
        let maxByNyquist = Int(HREncoder.nyquistLimit / max(fundamental, 0.0001))
        if count > maxByNyquist { count = max(1, maxByNyquist) }
        if count > HRCore.maxHarmonics { count = HRCore.maxHarmonics }

        var windowed = [Float](repeating: 0, count: n)
        for i in 0..<n { windowed[i] = x[i] * window[i] }

        // 2. 每个谐波的幅度与「频带中间」的噪声水平
        var harmonicLevel = [Float](repeating: 0, count: count)
        var noiseLevel = [Float](repeating: 0, count: count)
        let scale: Float = 2.0 / max(windowSum, 1)
        for k in 0..<count {
            let f = fundamental * Float(k + 1)
            if f >= HREncoder.nyquistLimit {
                harmonicLevel[k] = 0
                noiseLevel[k] = 0
                continue
            }
            let amp = HREncoder.magnitude(windowed, f) * scale
            let mid = HREncoder.magnitude(windowed, f + fundamental * 0.5) * scale
            harmonicLevel[k] = amp
            noiseLevel[k] = mid
        }

        // 3. 清浊：谐波明显高出频带中间，说明这一段有周期结构
        var bandScore = [Int](repeating: 0, count: 8)
        var bandSeen = [Int](repeating: 0, count: 8)
        for k in 0..<count {
            let f = fundamental * Float(k + 1)
            var band = Int(fundamental * Float(k + 1) * 16.0)
            band = band < 0 ? 0 : (band > 7 ? 7 : band)
            bandSeen[band] += 1
            if harmonicLevel[k] > max(noiseLevel[k] * 1.6, 1.0) {
                bandScore[band] += 1
            } else {
                bandScore[band] -= 1
            }
        }
        var bandVoiced = [Bool](repeating: false, count: 8)
        for b in 0..<8 {
            if bandSeen[b] == 0 {
                // 这个频带没有谐波落进来（低音高时高段是空的），沿用上一个频带
                bandVoiced[b] = b > 0 ? bandVoiced[b - 1] : false
            } else {
                bandVoiced[b] = bandScore[b] > 0
            }
        }

        // 4. 平均幅度 → 增益码本
        var logAmps = [Float](repeating: 0, count: count)
        let bias = HREncoder.levelBias
        var sumLog: Float = 0
        for k in 0..<count {
            let amp = max(harmonicLevel[k], 0.5)
            logAmps[k] = Float(log2(Double(amp))) + bias
            sumLog += logAmps[k]
        }
        let meanLog = count > 0 ? sumLog / Float(count) : 0
        let gainTarget = meanLog + HRTables.halfLog2Count[count]
        let carried = HRCodebook.previousGainWeight * state.log2Gain

        var gainIndex: Int32 = 0
        var gainError = Float.greatestFiniteMagnitude
        for i in 0..<HRTables.gain.count {
            let value = HRCodebook.gainWeight * HRTables.gain[i] + carried
            let error = abs(value - gainTarget)
            if error < gainError {
                gainError = error
                gainIndex = Int32(i)
            }
        }

        // 5. 谱形：先减掉预测，再用码本逼近残差
        var prediction = [Float](repeating: 0, count: HRCore.harmonicSlots)
        HRDequant.predict(state, harmonicCount: count, out: &prediction)
        var predictionMean: Float = 0
        for k in 0..<count { predictionMean += prediction[k] }
        predictionMean = count > 0 ? predictionMean / Float(count) : 0

        var residualTarget = [Float](repeating: 0, count: HRCore.harmonicSlots)
        for k in 0..<count {
            residualTarget[k] = (logAmps[k] - meanLog) - (prediction[k] - predictionMean)
        }

        let shape = quantizeShape(target: residualTarget, count: count)
        let voicingIndex = quantizeVoicing(bandVoiced)

        var fields = [Int32](repeating: 0, count: HRField.count)
        fields[HRField.pitch] = Int32(pitchIndex)
        fields[HRField.voicing] = Int32(voicingIndex)
        fields[HRField.gain] = gainIndex
        fields[HRField.shapeLow] = shape.low
        fields[HRField.shapeHigh] = shape.high
        for i in 0..<4 { fields[HRField.detail1 + i] = shape.details[i] }

        if rms < HREncoder.silenceRMS {
            // 静音帧按「清音 + 最低增益」发，避免把底噪放大成一片沙沙声
            fields[HRField.voicing] = 0
        }

        // 预测器必须和接收端一样往前推一步，否则下一帧的残差基准就偏了
        _ = HRDequant.dequantize(&state, fields)
        return fields
    }

    // MARK: - 基音

    /// 归一化自相关定基音，返回基频（周期/采样）
    private func estimateFundamental(_ x: [Float]) -> Float {
        let n = x.count
        let minLag = 16
        let maxLag = min(150, n - 40)
        guard maxLag > minLag else { return 0.02 }

        var scores = [Float](repeating: 0, count: maxLag + 1)
        var best: Float = 0
        for lag in minLag...maxLag {
            var num: Float = 0
            var e0: Float = 0
            var e1: Float = 0
            let limit = n - lag
            var i = 0
            while i < limit {
                let a = x[i]
                let b = x[i + lag]
                num += a * b
                e0 += a * a
                e1 += b * b
                i += 1
            }
            let denom = Float(sqrt(Double(e0 * e1)))
            let score = denom > 1e-6 ? num / denom : 0
            scores[lag] = score
            if score > best { best = score }
        }
        guard best > 0.2 else { return 1.0 / Float(minLag) }

        // 取「第一个足够高的峰」，而不是全局最大：全局最大常常是真实周期的整数倍，
        // 那会把男声判低一个八度，听起来像慢速的机器人。
        for lag in minLag...maxLag where scores[lag] >= best * 0.88 {
            return 1.0 / Float(lag)
        }
        return 1.0 / Float(minLag)
    }

    /// 最接近的码本音高索引（对数域比较，带迟滞）
    private func nearestPitch(_ fundamental: Float) -> Int {
        let f = max(fundamental, 0.005)
        let logF = log2(Double(f))
        var bestIndex = 0
        var bestError = Double.greatestFiniteMagnitude
        for i in 0..<HRTables.pitchFundamental.count {
            let e = abs(log2(Double(HRTables.pitchFundamental[i])) - logF)
            if e < bestError {
                bestError = e
                bestIndex = i
            }
        }
        // 迟滞：和上一帧差不到 5%，就沿用上一帧，免得两帧之间来回跳
        if lastPitchIndex >= 0 && lastPitchIndex < HRTables.pitchFundamental.count {
            let last = log2(Double(HRTables.pitchFundamental[lastPitchIndex]))
            if abs(last - logF) < bestError * 1.05 + 0.02 {
                return lastPitchIndex
            }
        }
        return bestIndex
    }

    /// 单频 DFT 幅度（Goertzel 递推）
    private static func magnitude(_ x: [Float], _ frequency: Float) -> Float {
        let w = 2.0 * Double.pi * Double(frequency)
        let c = Float(cos(w))
        let s = Float(sin(w))
        var re: Float = 0
        var im: Float = 0
        var cw: Float = 1
        var sw: Float = 0
        for v in x {
            re += v * cw
            im -= v * sw
            let t = cw * c - sw * s
            sw = sw * c + cw * s
            cw = t
        }
        return Float(sqrt(Double(re * re + im * im)))
    }

    // MARK: - 清浊量化

    private func quantizeVoicing(_ bandVoiced: [Bool]) -> Int {
        var bestIndex = 0
        var bestScore = Int.max
        for row in 0...HREncoder.maxVoicingIndex {
            var score = 0
            for b in 0..<8 {
                let wanted = bandVoiced[b] ? 1.0 : 0.0
                if HRTables.voicing[row * 8 + b] != wanted { score += 1 }
            }
            if score < bestScore {
                bestScore = score
                bestIndex = row
            }
        }
        return bestIndex
    }

    // MARK: - 谱形量化

    private struct ShapeResult {
        var low: Int32 = 0
        var high: Int32 = 0
        var details = [Int32](repeating: 0, count: 4)
        var error: Float = 0
    }

    /// 目标残差 → (shapeLow, shapeHigh, 4 个 detail)
    ///
    /// 码本结构：`shapeLow` 给低频段 3 个系数、`shapeHigh` 给高频段 4 个，各频带再用
    /// 一个 `detail` 码字补细节。搜索分两步：先按系数距离各挑 4 个候选，再对 16 种组合
    /// 用解码端的 `shapeResidual` 算真实误差——系数距离只是启发式，最终还是要看重建结果。
    private func quantizeShape(target: [Float], count: Int) -> ShapeResult {
        var result = ShapeResult()
        guard count >= 1 else { return result }

        // 每个频带的谐波数
        var sizes = [Int](repeating: 0, count: 4)
        for b in 0..<4 {
            sizes[b] = Int(HRTables.bandSizes[count * 4 + b])
            if sizes[b] < 0 { sizes[b] = 0 }
        }

        // 1. 每个频带做正向 DCT，拿到目标系数
        //
        //    `inverseDct` 的列不是单位范数：第 0 列是 n，其余是 2n（矩阵第 0 行系数 1、
        //    其余行系数 2，即逆 DCT-III 的归一化）。正向变换必须按这个尺度走，
        //    否则系数整体放大小十倍，码本搜索会全都选到边缘项。
        var blockTarget = [[Float]](repeating: [], count: 4)
        for b in 0..<4 {
            let n = sizes[b]
            var coeff = [Float](repeating: 0, count: max(n, 1))
            if n >= 1 {
                let base = (n - 1) * 324
                var offset = 0
                for i in 0..<b { offset += sizes[i] }
                for c in 0..<n {
                    var sum: Float = 0
                    for j in 0..<n {
                        let v = offset + j < target.count ? target[offset + j] : 0
                        sum += HRTables.inverseDct[base + j * 18 + c] * v
                    }
                    coeff[c] = sum / Float(c == 0 ? n : 2 * n)
                }
            }
            blockTarget[b] = coeff
        }

        // 2. 由各频带的前两个系数反推 8 个「pairs」，再转成低频 / 高频各 3、4 个系数
        var pairs = [Float](repeating: 0, count: 8)
        for b in 0..<4 {
            let c0 = blockTarget[b].count > 0 ? blockTarget[b][0] : 0
            let c1 = blockTarget[b].count > 1 ? blockTarget[b][1] : 0
            pairs[2 * b] = c0 + 0.70710678 * c1
            pairs[2 * b + 1] = c0 - 0.70710678 * c1
        }
        var lowTarget = [Float](repeating: 0, count: 3)
        var highTarget = [Float](repeating: 0, count: 4)
        let dct8 = 7 * 324
        var coefficients = [Float](repeating: 0, count: 8)
        for c in 1..<8 {
            var sum: Float = 0
            // 8 点矩阵的列范数同样是 n=8 / 2n=16
            for r in 0..<8 { sum += HRTables.inverseDct[dct8 + r * 18 + c] * pairs[r] }
            coefficients[c] = sum / 16
        }
        for i in 0..<3 { lowTarget[i] = coefficients[1 + i] }
        for i in 0..<4 { highTarget[i] = coefficients[4 + i] }

        // 3. 各挑 4 个候选
        let lowCandidates = nearestRows(table: HRTables.shapeLow, stride: 3, target: lowTarget, limit: 4)
        let highCandidates = nearestRows(table: HRTables.shapeHigh, stride: 4, target: highTarget, limit: 4)

        // 4. 组合评估
        var bestError = Float.greatestFiniteMagnitude
        var bestLow: Int32 = 0
        var bestHigh: Int32 = 0
        var bestDetails = [Int32](repeating: 0, count: 4)

        var residual = [Float](repeating: 0, count: HRCore.harmonicSlots)
        var meanTarget: Float = 0
        for k in 0..<count { meanTarget += target[k] }
        meanTarget = count > 0 ? meanTarget / Float(count) : 0

        for low in lowCandidates {
            for high in highCandidates {
                var details = [Int32](repeating: 0, count: 4)

                for b in 0..<4 {
                    let n = sizes[b]
                    guard n >= 3 else { continue }
                    // 这一带 0、1 号系数由 shapeLow / shapeHigh 决定，
                    // 只有 2…5 号系数归 detail 码字，所以这里直接拿它们比目标系数。
                    let table: [Float]
                    switch b {
                    case 0: table = HRTables.detail1
                    case 1: table = HRTables.detail2
                    case 2: table = HRTables.detail3
                    default: table = HRTables.detail4
                    }
                    let rows = table.count / 4
                    let wanted = n < 6 ? n : 6
                    var detail = 0
                    var detailError = Float.greatestFiniteMagnitude
                    if wanted > 2 {
                        for row in 0..<rows {
                            var error: Float = 0
                            for i in 0..<(wanted - 2) {
                                let t = blockTarget[b].count > (2 + i) ? blockTarget[b][2 + i] : 0
                                let d = table[row * 4 + i] - t
                                error += d * d
                            }
                            if error < detailError {
                                detailError = error
                                detail = row
                            }
                        }
                    }
                    details[b] = Int32(detail)
                }

                var fields = [Int32](repeating: 0, count: HRField.count)
                fields[HRField.shapeLow] = Int32(low)
                fields[HRField.shapeHigh] = Int32(high)
                for i in 0..<4 { fields[HRField.detail1 + i] = details[i] }
                HRDequant.shapeResidual(harmonicCount: count, fields: fields, out: &residual)

                var sum: Float = 0
                for k in 0..<count { sum += residual[k] }
                let mean = count > 0 ? sum / Float(count) : 0
                var error: Float = 0
                for k in 0..<count {
                    let d = (residual[k] - mean) - (target[k] - meanTarget)
                    error += d * d
                }
                if error < bestError {
                    bestError = error
                    bestLow = Int32(low)
                    bestHigh = Int32(high)
                    bestDetails = details
                }
            }
        }

        result.low = bestLow
        result.high = bestHigh
        result.details = bestDetails
        result.error = bestError
        return result
    }

    /// 按欧氏距离挑最近的若干行
    private func nearestRows(table: [Float], stride: Int, target: [Float], limit: Int) -> [Int] {
        let rows = table.count / stride
        var best = [(index: Int, error: Float)]()
        for row in 0..<rows {
            var error: Float = 0
            for i in 0..<stride {
                let d = table[row * stride + i] - target[i]
                error += d * d
            }
            if best.count < limit {
                best.append((row, error))
                best.sort { $0.error < $1.error }
            } else if let last = best.last, error < last.error {
                best[limit - 1] = (row, error)
                best.sort { $0.error < $1.error }
            }
        }
        return best.map { $0.index }
    }

    // MARK: - 电平标定

    /// 用解码器量一次「已知参数 → 输出 RMS」，把码本的归一化幅度换算成 16 位满幅。
    ///
    /// 这一步不能省：码本里的增益是相对量，不同实现之间差十几个 dB 很常见；
    /// 硬编码一个偏移量，要么轻得像耳语，要么一开口就削顶。
    private static func calibrateIfNeeded() {
        guard !levelBiasDone else { return }
        levelBiasDone = true

        let decoder = HRDecoder()
        let pitchIndex = 30
        var fields = [Int32](repeating: 0, count: HRField.count)
        fields[HRField.pitch] = Int32(pitchIndex)
        fields[HRField.voicing] = 0
        fields[HRField.gain] = 18
        let bits = HRFrame.rotatedFromStandard(HRFrame.bitsFromFields(fields))

        var pcm = [Int16](repeating: 0, count: HRCore.frameSamples)
        var rms: Float = 0
        for pass in 0..<6 {
            decoder.decode(bits: bits, pcm: &pcm)
            if pass >= 4 {
                var sum: Float = 0
                for v in pcm { sum += Float(v) * Float(v) }
                rms = Float(sqrt(Double(sum / Float(pcm.count))))
            }
        }

        let count = HRTables.pitchHarmonicCount[pitchIndex]
        let gain = HRCodebook.gainWeight * HRTables.gain[18]
        let meanLog = gain - HRTables.halfLog2Count[Int(count)]
        if rms > 8 {
            levelBias = meanLog - Float(log2(Double(rms)))
        }
    }
}
