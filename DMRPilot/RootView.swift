//
//  RootView.swift
//  DMRPilot
//

import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            HotspotView()
                .tabItem { Label("热点", systemImage: "antenna.radiowaves.left.and.right") }

            DirectoryView()
                .tabItem { Label("目录", systemImage: "book.closed") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
