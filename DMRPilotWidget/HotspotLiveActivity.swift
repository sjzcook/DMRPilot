//
//  HotspotLiveActivity.swift
//  DMRPilotWidget
//
//  锁屏卡片 + 灵动岛（Dynamic Island）的界面。
//
//  只负责画，不碰网络：主 App 每隔一两秒把 `ContentState` 推过来（见
//  `DMRPilot/LiveActivityController.swift`）。所以这里所有状态都从 `context.state`
//  读，不要自己算时间或查库。
//

import ActivityKit
import SwiftUI
import WidgetKit

struct HotspotLiveActivity: Widget {

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HotspotActivityAttributes.self) { context in
            LockScreenCard(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.45))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor(context.state))
                            .frame(width: 8, height: 8)
                        Text(identityText(context.attributes))
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.signal)
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(signalColor(context.state))
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(talkgroupText(context.state))
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        if context.state.isTransmitting, let start = context.state.txStartedAt {
                            // 计时交给系统：否则得每秒推一次内容，会被节流。
                            Text(timerInterval: start...start.addingTimeInterval(3600), countsDown: false)
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.red)
                        } else {
                            Text(statusLine(context.state))
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    LevelBar(level: context.state.level, color: statusColor(context.state))
                        .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor(context.state))
            } compactTrailing: {
                Text(context.state.talkgroup > 0 ? "\(context.state.talkgroup)" : "—")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } minimal: {
                Image(systemName: context.state.isTransmitting
                      ? "mic.fill"
                      : "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(statusColor(context.state))
            }
            .keylineTint(statusColor(context.state))
        }
    }
}

// MARK: - 锁屏卡片

private struct LockScreenCard: View {
    let attributes: HotspotActivityAttributes
    let state: HotspotActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: state.isTransmitting ? "mic.fill" : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusColor(state))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(identityText(attributes))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(attributes.host)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(state.signal)
                        .font(.callout.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(signalColor(state))
                    Text(talkgroupText(state))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            LevelBar(level: state.level, color: statusColor(state))

            HStack(spacing: 8) {
                Text(statusLine(state))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 4)

                if state.isTransmitting, let start = state.txStartedAt {
                    Text(timerInterval: start...start.addingTimeInterval(3600), countsDown: false)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    Text("\(state.rxFrames) 帧")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .padding(14)
    }
}

// MARK: - 小部件

private struct LevelBar: View {
    let level: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(color)
                    .frame(width: max(3, geometry.size.width * CGFloat(max(0, min(1, level)))))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - 文案与配色

/// 呼号优先，没有就退到 DMR ID——两者都没有时显示占位。
private func identityText(_ attributes: HotspotActivityAttributes) -> String {
    if !attributes.callsign.isEmpty { return attributes.callsign }
    if !attributes.dmrId.isEmpty { return "DMR \(attributes.dmrId)" }
    return "EasyDMR"
}

private func talkgroupText(_ state: HotspotActivityAttributes.ContentState) -> String {
    state.talkgroup > 0 ? "TG \(state.talkgroup)" : "无通话组"
}

/// 一句话状态：发射 > 有人说话 > 守听 > 其他（连接中 / 已断开）。
private func statusLine(_ state: HotspotActivityAttributes.ContentState) -> String {
    if state.isTransmitting { return "正在发射 · \(talkgroupText(state))" }
    if let speaker = state.speakerLabel, !speaker.isEmpty { return "\(speaker) 正在说话" }
    if state.isOnline { return "守听中 · \(talkgroupText(state))" }
    return state.statusText
}

/// 发射红、在线绿、其余橙。
private func statusColor(_ state: HotspotActivityAttributes.ContentState) -> Color {
    if state.isTransmitting { return .red }
    if state.isOnline { return .green }
    return .orange
}

/// 信号读数：`59` 以上偏绿，`57` 以下偏黄，没有信号灰。
private func signalColor(_ state: HotspotActivityAttributes.ContentState) -> Color {
    guard state.signal != "—", let first = state.signal.first else { return .white.opacity(0.5) }
    if state.signal.contains("+") { return .green }
    // `59` / `56` 这种：第二位是 S 值
    if let sValue = state.signal.dropFirst().first, let s = Int(String(sValue)) {
        return s >= 8 ? .green : (s >= 6 ? .yellow : .orange)
    }
    return first == "5" ? .green : .white
}
