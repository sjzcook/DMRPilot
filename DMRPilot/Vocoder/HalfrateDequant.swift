//
//  HalfrateDequant.swift
//  DMRPilot
//
//  参数反量化：把 9 个帧字段变成音高、谐波个数、清浊、log2 谐波幅度和增益，
//  并用上一帧的谱形做预测。
//
//  移植自 DroidStar 的 mbe/dequant.cc、mbe/codebook_set.cc。
//

import Foundation

// MARK: - 帧类型

enum HRFrameKind: Equatable {
    case voice     // 音高索引 0..119
    case tone      // 124..125：固定基频 1/32、14 个谐波
    case erasure   // 120..123：参数清零、预测器复位
    case reserved  // 126..127：按丢帧处理
}

// MARK: - 预测器状态

struct HRDequantState {
    var harmonicCount: Int32 = Int32(HRCore.resetHarmonicCount)
    var log2Gain: Float = 0
    /// 上一帧的 log2 谐波幅度，[l] 对应 l = 1..L
    var log2Amplitude = [Float](repeating: 0, count: HRCore.maxHarmonics + 2)
}

// MARK: - 解出的参数

struct HRFrameParams {
    var kind: HRFrameKind = .voice
    var fundamental: Float = 0
    var omega: Float = 0
    var harmonicCount: Int32 = 0
    var harmonicVoiced = [UInt8](repeating: 0, count: HRCore.maxHarmonics + 1)
    var log2Amplitude = [Float](repeating: 0, count: HRCore.maxHarmonics + 1)
    var log2Gain: Float = 0
    var fields = [Int32](repeating: 0, count: HRField.count)
}

// MARK: - 码本常量

enum HRCodebook {
    static let prediction: Float = 0.65
    static let gainWeight: Float = 1.0
    static let previousGainWeight: Float = 0.5
    static let pitchCount = 120
    static let voicingCount = 32
    static let detailStride = [1, 1, 1, 1]

    static let detailTables: [[Float]] = [
        HRTables.detail1, HRTables.detail2, HRTables.detail3, HRTables.detail4
    ]
}

// MARK: - 反量化

enum HRDequant {

    private static let halfSqrtHalf: Float = 0.35355338
    private static let twoPi: Float = 6.2831855
    private static let voicePitchCount = 120
    private static let tonePitchEnd = 126
    private static let erasurePitchEnd = 124
    private static let toneHarmonicCount = 14
    private static let toneFundamental: Float = 0.03125

    static func reset(_ state: inout HRDequantState) {
        state = HRDequantState()
    }

    /// 由 shape 字段得到 L 个谐波的谱形残差，写入 out[0..<L]
    static func shapeResidual(harmonicCount: Int, fields: [Int32], out: inout [Float]) {
        let lowIndex = Int(fields[HRField.shapeLow])
        let highIndex = Int(fields[HRField.shapeHigh])
        let lowBase = lowIndex * 3
        let highBase = highIndex * 4

        let coefficients: [Float] = [
            0.0,
            HRTables.shapeLow[lowBase],
            HRTables.shapeLow[lowBase + 1],
            HRTables.shapeLow[lowBase + 2],
            HRTables.shapeHigh[highBase],
            HRTables.shapeHigh[highBase + 1],
            HRTables.shapeHigh[highBase + 2],
            HRTables.shapeHigh[highBase + 3],
        ]

        var pairs = [Float](repeating: 0, count: 8)
        let dct8 = 7 * 324
        for r in 0..<8 {
            var sum: Float = 0
            for c in 0..<8 {
                sum = sum + HRTables.inverseDct[dct8 + r * 18 + c] * coefficients[c]
            }
            pairs[r] = sum
        }

        let sizesBase = harmonicCount * 4
        var position = 0
        for block in 0..<4 {
            let n = Int(HRTables.bandSizes[sizesBase + block])
            var blockCoefficients = [Float](repeating: 0, count: 18)
            let a = pairs[2 * block]
            let b = pairs[2 * block + 1]
            blockCoefficients[0] = (a + b) * 0.5
            blockCoefficients[1] = (a - b) * halfSqrtHalf

            if n >= 3 {
                let detailCount = n < 6 ? n : 6
                let row = HRCodebook.detailStride[block] * Int(fields[HRField.detail1 + block])
                let table = HRCodebook.detailTables[block]
                for i in 0..<(detailCount - 2) {
                    blockCoefficients[2 + i] = table[row * 4 + i]
                }
            } else if n < 1 {
                continue
            }

            let dct = (n - 1) * 324
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<n {
                    sum = sum + HRTables.inverseDct[dct + i * 18 + c] * blockCoefficients[c]
                }
                if position < out.count {
                    out[position] = sum
                }
                position += 1
            }
        }
    }

    /// 预测：把上一帧的幅度重采样到 L 个谐波并乘以预测系数
    static func predict(_ state: HRDequantState, harmonicCount: Int, out: inout [Float]) {
        if harmonicCount < 1 { return }

        let previousCount = Int(state.harmonicCount)
        var previous = state.log2Amplitude

        if harmonicCount > previousCount {
            let last = previous[previousCount]
            var i = previousCount + 1
            while i <= harmonicCount && i < previous.count {
                previous[i] = last
                i += 1
            }
        }
        previous[0] = previous[1]

        let ratio = Float(previousCount) / Float(harmonicCount)
        let rho = HRCodebook.prediction
        for k in 1...harmonicCount {
            let x = ratio * Float(k)
            let i = Int(HRCore.toInt32Sat(x))
            let frac = x - Float(HRCore.toInt32Sat(x))
            let j = i < HRCore.maxHarmonics ? i : HRCore.maxHarmonics
            let indexI = i < previous.count ? i : previous.count - 1
            let indexJ = j + 1 < previous.count ? j + 1 : previous.count - 1
            let a = (1.0 - frac) * rho * previous[indexI]
            let b = frac * rho * previous[indexJ]
            out[k - 1] = a + b
        }
    }

    /// 解一帧
    static func dequantize(_ state: inout HRDequantState, _ fields: [Int32]) -> (HRFrameKind, HRFrameParams) {
        var params = HRFrameParams()
        params.fields = fields

        let pitch = Int(fields[HRField.pitch])
        let hasPitch = pitch < voicePitchCount

        var kind: HRFrameKind
        var count = 0
        var fundamental: Float = 0

        if hasPitch {
            kind = .voice
            fundamental = HRTables.pitchFundamental[pitch]
            count = Int(HRTables.pitchHarmonicCount[pitch])
        } else if pitch < erasurePitchEnd {
            kind = .erasure
        } else if pitch < tonePitchEnd {
            kind = .tone
            count = toneHarmonicCount
            fundamental = toneFundamental
        } else {
            kind = .reserved
        }

        if kind == .erasure || kind == .reserved {
            reset(&state)
            params.kind = kind
            return (kind, params)
        }

        let newGain = HRCodebook.gainWeight * HRTables.gain[Int(fields[HRField.gain])]
        let carriedGain = HRCodebook.previousGainWeight * state.log2Gain

        var residual = [Float](repeating: 0, count: HRCore.harmonicSlots)
        var prediction = [Float](repeating: 0, count: HRCore.harmonicSlots)
        shapeResidual(harmonicCount: count, fields: fields, out: &residual)
        predict(state, harmonicCount: count, out: &prediction)

        var residualSum: Float = 0
        var predictionSum: Float = 0
        for i in 0..<count {
            residualSum = residualSum + residual[i]
            predictionSum = predictionSum + prediction[i]
        }

        let halfLog2Count = HRTables.halfLog2Count[count]
        let reciprocalCount = HRTables.reciprocalCount[count]
        let gain = newGain + carriedGain

        for i in 0..<state.log2Amplitude.count { state.log2Amplitude[i] = 0 }
        if count >= 1 {
            let offset = gain - halfLog2Count - residualSum * reciprocalCount
            let predictionMean = predictionSum * reciprocalCount
            for k in 0..<count {
                var value = residual[k] + prediction[k]
                value = value - predictionMean
                value = offset + value
                state.log2Amplitude[k + 1] = value
            }
        }
        state.harmonicCount = Int32(count)
        state.log2Gain = gain

        params.kind = kind
        params.fundamental = fundamental
        params.omega = fundamental * twoPi
        params.harmonicCount = Int32(count)
        params.log2Gain = gain

        for i in 0..<params.harmonicVoiced.count {
            params.harmonicVoiced[i] = 0
            params.log2Amplitude[i] = 0
        }

        let bandsBase = Int(fields[HRField.voicing]) * 8
        var i = 0
        while i < count && i <= HRCore.maxHarmonics {
            var voiced = 0
            if hasPitch {
                let band = Int(HRCore.toInt32Sat(fundamental * (Float(i + 1) * 16.0)))
                voiced = Int(HRTables.voicing[bandsBase + (band < 7 ? band : 7)])
            }
            params.harmonicVoiced[i] = UInt8(voiced)
            params.log2Amplitude[i] = state.log2Amplitude[i + 1]
            i += 1
        }
        return (kind, params)
    }
}
