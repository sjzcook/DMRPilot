//
//  HalfrateOptions.swift
//  DMRPilot
//
//  解码器与合成器的全部调音参数，默认值取自 DroidStar 的 mbe/decoder_options.h
//  （源码里的十六进制浮点在注释里给了十进制，这里直接用十进制字面量，
//  Swift 会取最近的 float，与 C++ 端一致）。
//

import Foundation

struct HROptions {

    // 帧解码与参数整形
    var outputGain: Float = 2.08
    var mixedVoicedShare: Float = 0.85
    var mixedPulseShare: Float = 0.5
    var pulseNoisePulseWeight: Float = 0.9
    var pulseNoiseNoiseWeight: Float = 0.62
    var voicedWeight: Float = 1.0
    var highBandStart: Float = 0.65
    var highBandTilt: Float = 0.55
    var pulsePitchIndex: Int32 = 119
    var pulseWindow: Float = 88.0
    var pulseWindowCenter: Int32 = 62
    var pulseEnable: Int32 = 1
    var pulsePositionLow: Int32 = 98
    var pulsePositionHigh: Int32 = 16
    var pulsePairFirstStart: Float = 101.0
    var pulsePairFirstStep: Float = 11.8
    var pulsePairSecondStart: Float = 21.0
    var pulsePairSecondStep: Float = 11.8
    var phaseDispersion: Float = 0.3
    var phaseLevelOffset: Float = 0.0
    var phaseTaps: Int32 = 19
    var phaseOddTaps: Int32 = 1
    var silenceGain: Float = 0.3
    var silencePredictor: Int32 = 3
    var rotatedLayout: Int32 = 1
    var toneGain: Float = 1.0

    // 共振峰增强
    var enhance: Int32 = 1
    var enhanceStrength: Float = 0.5
    var enhanceMinWeight: Float = 0.3
    var enhanceMaxWeight: Float = 2.0
    var enhanceBypassDivisor: Int32 = 0
    var enhancePowerHigh: Float = 0.85
    var enhancePowerLow: Float = 0.6
    var enhanceSplitFrequency: Float = 0.125

    // 丢帧隐藏
    var repeatMax: Int32 = 3
    var repeatGain: Float = 1.0
    var repeatHighGain: Float = 1.0
    var repeatHighStart: Float = 0.3
    var comfortNoiseLevel: Float = 1.0

    // 输出级
    var highpassHz: Float = 0.0
    var frameLimiter: Int32 = 1
    var frameLimiterKneeDb: Float = 78.5
    var frameLimiterRatio: Float = 0.3
    var limiterThreshold: Float = 28000.0

    // 合成器
    var unvoicedGain: Float = 0.85
    var pulseGain: Float = 1.0
    var pulseLength: Float = 48.0
    var pulseMinimumPhase: Int32 = 0
    var pulseShift: Int32 = 0
    var voicedFadeStart: Float = 0.0
    var voicedFadeEnd: Float = 160.0
    var noiseOffset: Int32 = 0
    var initialPhase: Int32 = 0
    var unvoicedTopExtend: Float = 0.0
    var unvoicedLowCut: Int32 = 1
    var phaseTracking: Int32 = 1
    var amplitudeLogInterp: Int32 = 1
    var amplitudeHold: Int32 = 0
    var amplitudeFrequencyMap: Int32 = 0
    var noiseMethod: Int32 = 1
    var noiseCoherentBins: Int32 = 64
    var noisePhaseJitter: Float = 0.5
    var noiseWhite: Int32 = 0
    var noiseGainBin1: Float = 0.0
    var noiseGainBins23: Float = 0.15
    var pulseHighpassHz: Float = 0.0
    var noiseSeed: Int32 = 0
    var voicingOffStart: Float = 5.0
    var voicingOffEnd: Float = 50.0
    var voicingOnStart: Float = 55.0
    var voicingOnEnd: Float = 90.0
    var harmonicFadeStart: Float = 0.0
    var harmonicFadeEnd: Float = 160.0
    var pitchGlideStart: Int32 = 0
    var pitchGlideEnd: Int32 = 160
    var amplitudeGlideStart: Int32 = 0
    var amplitudeGlideEnd: Int32 = 160
}

// MARK: - 共振峰增强参数

struct HREnhanceOptions {
    var mode: Int32 = 1
    var strength: Float = 0.5
    var minWeight: Float = 0.3
    var maxWeight: Float = 2.0
    var bypassDivisor: Int32 = 0
    var powerHigh: Float = 0.85
    var powerLow: Float = 0.6
    var splitFrequency: Float = 0.125
}

extension HROptions {
    var enhanceOptions: HREnhanceOptions {
        HREnhanceOptions(
            mode: enhance,
            strength: enhanceStrength,
            minWeight: enhanceMinWeight,
            maxWeight: enhanceMaxWeight,
            bypassDivisor: enhanceBypassDivisor,
            powerHigh: enhancePowerHigh,
            powerLow: enhancePowerLow,
            splitFrequency: enhanceSplitFrequency
        )
    }
}
