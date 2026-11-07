//
//  RootView.swift
//  DMRPilot
//

import SwiftUI

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
