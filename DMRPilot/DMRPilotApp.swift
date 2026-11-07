//
//  DMRPilotApp.swift
//  DMRPilot
//
//  iOS 16+ / SwiftUI
//

import SwiftUI

@main
struct DMRPilotApp: App {
    /// 用 `AppState.shared` 而不是新建：快捷指令里的 PTT 必须和界面上看到的是
    /// 同一个连接对象，否则会另起一个没连上的实例。
    @StateObject private var app = AppState.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.hotspot)
                .environmentObject(app.callsigns)
                .environmentObject(app.hostStore)
                .environmentObject(CallLogStore.shared)
                .tint(.blue)
                // 主题：`nil` = 跟随系统，`.light` / `.dark` = 强制覆盖。
                // 放在最外层，弹出的 sheet / 全屏页面也一起继承。
                .preferredColorScheme(app.settings.theme.colorScheme)
        }
    }
}
