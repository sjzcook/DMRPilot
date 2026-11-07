//
//  DMRPilotApp.swift
//  DMRPilot
//
//  iOS 16+ / SwiftUI
//

import SwiftUI

@main
struct DMRPilotApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.hotspot)
                .environmentObject(app.callsigns)
                .environmentObject(CallLogStore.shared)
                .tint(.blue)
        }
    }
}
