//
//  LogConsoleView.swift
//  DMRPilot
//
//  协议日志：每一帧的十六进制原文，排查 MSTNAK / 心跳 / 帧长问题用。
//

import SwiftUI

struct LogConsoleView: View {
    @EnvironmentObject private var hotspot: HomebrewClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if hotspot.entries.isEmpty {
                    Text("暂无日志。连接之后这里会记录每一条协议帧。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(hotspot.entries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: entry.kind.symbol)
                                .font(.caption2)
                                .foregroundStyle(color(for: entry.kind))
                                .padding(.top, 2)

                            Text(Fmt.clock.string(from: entry.time))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .padding(.top, 1)

                            Text(entry.text)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let hex = entry.hex {
                            Text(hex)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.plain)
            .navigationTitle("协议日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) {
                        hotspot.clearLog()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(hotspot.entries.isEmpty)
                }
            }
        }
    }

    private func color(for kind: LogEntry.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .tx: return .blue
        case .rx: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
