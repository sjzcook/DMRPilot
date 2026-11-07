//
//  DMRPilotWidgetBundle.swift
//  DMRPilotWidget
//
//  扩展的入口。目前只有一个 Live Activity（锁屏卡片 + 灵动岛），
//  以后要加桌面小组件就往 body 里再塞一个 Widget。
//

import SwiftUI
import WidgetKit

@main
struct DMRPilotWidgetBundle: WidgetBundle {
    var body: some Widget {
        HotspotLiveActivity()
    }
}
