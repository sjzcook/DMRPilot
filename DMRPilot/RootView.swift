//
//  RootView.swift
//  DMRPilot
//

import SwiftUI

extension AppTheme {
    /// 映射到 SwiftUI：`nil` 表示不覆盖系统外观（跟随系统）。
    ///
    /// 放在这里而不是 `Models.swift`，是因为 `ColorScheme` 属于 SwiftUI，
    /// 模型文件只依赖 Foundation，免得以后想在别处复用模型还得拖着 UI 框架。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            HotspotView()
                .tabItem { Label("首页", systemImage: "antenna.radiowaves.left.and.right") }

            CallLogView()
                .tabItem { Label("日志", systemImage: "list.bullet.rectangle") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
