//
//  HotspotView.swift
//  DMRPilot
//
//  首页：连接状态、PTT、当前讲话人 / 刚刚结束（由 DMRD 信令聚合）、协议日志入口。
//

import SwiftUI
import UIKit

struct HotspotView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var hotspot: HomebrewClient
    @EnvironmentObject private var callsigns: CallsignDirectory
    /// 服务器选择器从设置页搬过来了：首页直接挑服务器，数据源还是这一份。
    @EnvironmentObject private var hostStore: DMRHostStore
    @State private var pttPressed = false
    @State private var pttDenied = false
    /// 电平表的平滑值：快起慢落，免得读数在「59」和「53」之间抖。
    @State private var smoothedLevel: Double = 0
    /// 单呼号码框在屏幕上的位置（全局坐标）。
    ///
    /// 收起键盘靠「点列表任意位置」的手势实现，而点在号码框里是要继续输入，
    /// 所以得知道框在哪：框外的点才收键盘。
    @State private var privateFieldFrame: CGRect = .zero

    var body: some View {
        NavigationStack {
            List {
                Section {
                    statusCard
                }

                pttSection

                speakerSection

                if !recentSpeakerItems.isEmpty {
                    Section("刚刚结束") {
                        ForEach(recentSpeakerItems) { item in
                            speakerRow(item, at: Date())
                                .cardRow()
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            // 单呼时那一格是数字键盘，没有回车键。除了下滑收键盘以外，点框外任何地方
            // 也当成「输完了」：这里挂一个不抢事件的手势，只观察点击落在哪。
            // `simultaneousGesture` 不会挡住按钮 / 选择器本身的点击，键盘收起来的同时
            // 那一行该干什么还干什么。
            //
            // 位置一律用 `.global`：手势的触点和号码框上报的 frame 必须是同一套坐标，
            // 中途插一个具名坐标空间反而容易对不上（还会踩到 iOS 17 的弃用接口）。
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .global).onEnded { value in
                    // 只有单呼的号码框需要这个；组呼那边是菜单选择器，没有键盘。
                    guard app.settings.isPrivateCall else { return }
                    // 点在号码框里就是要接着敲数字，不能收。
                    if privateFieldFrame.contains(value.location) { return }
                    dismissKeyboard()
                }
            )
            // 号码框每帧布局后上报自己的位置（切换组呼 / 单呼、滚动、键盘顶起来都会变）。
            .onPreferenceChange(PrivateFieldFrameKey.self) { frame in
                privateFieldFrame = frame
            }
            // 下滑也能收键盘（数字键盘没有回车，这是另一条退路）。
            .scrollDismissesKeyboard(.interactively)
            // 电平随每个语音帧刷新（约 16 次/秒），原始值直接显示会在「59」和「53」之间乱跳：
            // 这里做一次快起慢落（上升 0.7、回落 0.12），读数稳住但话音一停也能很快掉下去。
            .onChange(of: hotspot.voiceLevel) { newValue in
                let target = Double(newValue)
                let factor = target > smoothedLevel ? 0.7 : 0.12
                smoothedLevel += (target - smoothedLevel) * factor
            }
            .navigationTitle("首页")
            .onAppear {
                // 切回本页时可能正有人在说话：onChange 不会补发，这里补一次。
                if let id = hotspot.currentSpeaker?.src { callsigns.request(id) }
            }
            // 通话组列表是选择器的数据源，进页面就先拿一次（有缓存时不重复请求）。
            .task { await app.loadTalkgroupsIfNeeded() }
            // 换人说话时立刻查一次呼号；已知的和刚查过没结果的都会被 CallsignDirectory 跳过，
            // 所以这里不用再判断，每句通话触发一次网络请求是可以接受的。
            .onChange(of: hotspot.currentSpeaker?.src) { newValue in
                guard let id = newValue else { return }
                callsigns.request(id)
            }
            .toolbar {
                // 协议日志按钮搬到设置页右上角了；这里只剩模式选择。
                ToolbarItem(placement: .navigationBarTrailing) {
                    modeMenu
                }
            }
        }
    }

    // MARK: - 模式选择

    /// 标题右侧的模式选择：DMR / YSF。
    ///
    /// 和 PTT 里的「组呼 / 单呼」用**同一个**触发器样式（`selectorLabel`）：
    /// 蓝色文字 + 小箭头，点开是下拉菜单，选中项不打勾——当前值是直接写在下拉按钮上的，
    /// 所以不需要对勾，也不会像系统 Picker 那样把标题和值挤在一起。
    ///
    /// 这里不直接写 `settings.homeMode`，而是走 `AppState.setHomeMode`：
    /// 它还要负责记/换服务器、把会话断干净，直接改设置会漏掉这些副作用。
    private var modeMenu: some View {
        Menu {
            ForEach(HomeMode.allCases) { mode in
                Button {
                    // 导航栏在列表外面，列表上那个「点空白收键盘」的手势够不到这里。
                    dismissKeyboard()
                    app.setHomeMode(mode)
                } label: {
                    Text(mode.rawValue)
                }
            }
        } label: {
            selectorLabel(app.settings.homeMode.rawValue)
        }
        .accessibilityLabel("模式选择，当前\(app.settings.homeMode.rawValue)")
    }

    /// 两个下拉选择器（导航栏的模式、PTT 角落的呼叫类型）共用的触发器样式。
    /// 抽出来是为了让两处看起来是同一套控件，改一处两边一起变。
    private func selectorLabel(_ text: String,
                               font: Font = .subheadline.weight(.semibold)) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(font)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .imageScale(.small)
        }
        .foregroundStyle(Color.accentColor)
        .contentShape(Rectangle())
    }

    // MARK: - 状态卡片

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 这一行的高度单独给个下限：未连接时右边没有 uptime 和静音按钮，
            // 只剩「圆点 + 状态文字」，会明显比在线时矮一截，看着像整块在跳动。
            // 只抬行高，字号保持 .headline 不动。
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)

                Text(hotspot.state.label)
                    .font(.headline)

                Spacer()

                if hotspot.state == .online {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(uptimeText(at: context.date))
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    // 连接时间右边的静音开关：和设置里「语音播放」是同一个设置，
                    // 只是放在这儿能边说边按。图标跟着状态切换。
                    Button(action: toggleAudio) {
                        Image(systemName: app.settings.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.footnote.weight(.semibold))
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(app.settings.audioEnabled ? Color.accentColor : Color.orange)
                    .accessibilityLabel(app.settings.audioEnabled ? "静音" : "恢复声音")
                }
            }
            .frame(minHeight: 38)

            if case .failed(let message) = hotspot.state {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 三格之间不再画竖分隔线（`Divider` 在分组列表里会渲染成两条灰线），
            // 靠间距区分即可，每格仍然是等宽的。
            HStack(spacing: 16) {
                Metric(title: (app.settings.usesEssid || app.settings.hotspotIdOverride > 0) ? "热点 ID" : "DMR ID",
                       value: app.settings.dmrId > 0 ? "\(app.settings.hotspotId)" : "未设置")
                Metric(title: "传输", value: app.settings.transport.short)
                Metric(title: "收帧", value: "\(hotspot.rxFrames)")
            }

            // 电平表整行铺开，读数（`59` / `59+20`）压在它上方，按业余无线电 S 表的规矩。
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: audioIcon)
                        .font(.caption)
                        .foregroundStyle(hotspot.isVoicePlaying ? Color.accentColor : Color.secondary)

                    Text(signalReport.text)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(signalReport.hasSignal ? Color.primary : Color.secondary)
                        .accessibilityLabel("信号报告 \(signalReport.text)")

                    Spacer(minLength: 0)
                }

                LevelMeter(level: displayLevel, segments: 18)
                    .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16)
            }
            .padding(.vertical, 4)

            // 服务器选择器（从设置页搬来）和目的地址并排，各占一半宽度；
            // 连接要用的两样东西都摆在按钮正上方，选完直接按。
            // 右上角模式菜单切到 YSF 时没有通话组概念，只显示服务器那一格，
            // 且服务器列表跟着切到 YSF 反射器那份。
            //
            // 这一格的内容由 PTT 上方的「组呼 / 单呼」决定：
            //   组呼 → 通话组选择器（原来的逻辑）
            //   单呼 → 直接输入对方 DMR ID 的输入框
            // 两个值分别存在 `settings.talkgroup` / `settings.privateId`，来回切不会丢。
            HStack(alignment: .top, spacing: 10) {
                HostPickerField(store: hostStore,
                                kind: app.settings.homeMode.hostKind,
                                settings: $app.settings) {
                    // 换服务器后自动断开重连（没在线时只保存），和原先设置页同一套行为。
                    app.restartForServerChange()
                }
                .frame(maxWidth: .infinity)

                if app.settings.homeMode != .ysf {
                    if app.settings.isPrivateCall {
                        PrivateIdField(id: $app.settings.privateId)
                            .frame(maxWidth: .infinity)
                            // 把框的位置报给列表：点框外收键盘时，框内的点击要放过。
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: PrivateFieldFrameKey.self,
                                        value: proxy.frame(in: .global)
                                    )
                                }
                            )
                    } else {
                        TalkgroupPickerField(talkgroups: app.talkgroups,
                                             selected: app.settings.talkgroup,
                                             isLoading: app.isLoadingTalkgroups,
                                             error: app.talkgroupsError,
                                             onSelect: { app.setTalkgroup($0) },
                                             onRefresh: { await app.reloadTalkgroups() })
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            // 连接按钮独占一行，整行可点。
            Button(action: toggleConnection) {
                Text(buttonTitle)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            // 连上之后按钮变成「断开连接」，底色改红——红色在这套界面里专门留给
            // 「会中断当前动作」的操作；连着的过程中（connecting 等）仍是主题色。
            .tint(hotspot.state == .online ? Color.red : Color.accentColor)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
    }

    // MARK: - PTT（按住说话）

    /// 状态卡下方的圆形 PTT：按住开始发射，松手停止。
    ///
    /// 交互用 `DragGesture(minimumDistance: 0)` 而不是 `Button`：Button 只有抬起时才有
    /// 回调，拿不到「按住期间」的状态，也就没法做「按住发射 / 松手停止」。
    ///
    /// 右上角（模块内部，不是 Section 标题）挂着「组呼 / 单呼」选择器：
    /// 和导航栏的 DMR / YSF 是同一个 `Menu` + `selectorLabel` 组合。
    /// 它只在 DMR 下出现——YSF 没有数字 ID，也就没有单呼这回事。
    private var pttSection: some View {
        Section {
            VStack(spacing: 10) {
                pttButton

                Text(pttStatusText)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(hotspot.isTransmitting ? Color.red : Color.secondary)
                    .animation(.none, value: hotspot.txSeconds)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            // 贴在整块内容的右上角：PTT 圆是居中的，所以这里不会碰到它。
            .overlay(alignment: .topTrailing) {
                if app.settings.homeMode == .dmr {
                    callModePicker
                }
            }
        }
    }

    /// 组呼 / 单呼切换。外形和导航栏的 DMR / YSF 完全一致（同一个 `selectorLabel`），
    /// 只是字号跟着这一块缩小一号。
    ///
    /// 绑定走 `AppState.setCallMode` 而不是直接写设置：它还要负责「切换后断开连接」
    /// 和收尾正在发射的那一句。
    private var callModePicker: some View {
        Menu {
            ForEach(CallMode.allCases) { mode in
                Button {
                    // 切走以后号码框会消失，键盘留着就没地方可点了。
                    dismissKeyboard()
                    app.setCallMode(mode)
                } label: {
                    Text(mode.title)
                }
            }
        } label: {
            selectorLabel(app.settings.callMode.title, font: .footnote.weight(.semibold))
        }
        .accessibilityLabel("呼叫类型，当前\(app.settings.callMode.title)")
    }

    private var pttButton: some View {
        let active = hotspot.isTransmitting
        // 三档：发射中红、连着能发蓝、没连上灰。以前是「发射中红 / 其他灰」，
        // 灰色在深色界面上和背景太接近，看不出能不能按，所以把「已连接」这一档改成蓝色。
        let connected = hotspot.state == .online
        let colors: [Color] = active
            ? [Color(red: 0.94, green: 0.30, blue: 0.26),
               Color(red: 0.70, green: 0.09, blue: 0.07)]
            : (connected
               ? [Color(red: 0.34, green: 0.60, blue: 0.98),
                  Color(red: 0.08, green: 0.31, blue: 0.74)]
               : [Color(red: 0.44, green: 0.47, blue: 0.54),
                  Color(red: 0.27, green: 0.29, blue: 0.35)])

        return ZStack {
            Circle()
                .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                .frame(width: 124, height: 124)
                .overlay(
                    Circle().stroke(Color.white.opacity(active ? 0.22 : 0.10), lineWidth: 1)
                )
                .shadow(color: active ? Color.red.opacity(0.45)
                                     : (connected ? Color.blue.opacity(0.35) : Color.black.opacity(0.16)),
                        radius: active ? 16 : 6, x: 0, y: 4)

            Text("PTT")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .kerning(1.5)
                .foregroundStyle(.white)
        }
        .frame(width: 148, height: 148)
        .scaleEffect(pttPressed ? 0.94 : 1)
        .opacity(canTransmit ? 1 : 0.45)
        .contentShape(Circle())
        .animation(.easeOut(duration: 0.12), value: pttPressed)
        // 用 highPriorityGesture 而不是 gesture：这一行在 List（ScrollView）里，
        // 普通手势会被列表的滚动识别器抢走，表现成「按下去没反应、要抬手才触发」。
        // 提到高优先级之后，起手就锁定在这个圆上，按住即开麦、抬手即收尾。
        //
        // `minimumDistance: 0` 是关键：默认的 10pt 会让「按住不动」永远等不到
        // onChanged，那就变成「点一下」而不是「按住」了。
        .highPriorityGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressPtt() }
                .onEnded { _ in releasePtt() }
        )
        .accessibilityLabel("按住发射")
        .accessibilityHint("按住时使用麦克风向\(app.settings.destinationText())发射，松手停止")
    }

    private var canTransmit: Bool {
        // YSF 不需要通话组，只要有呼号就能发。
        if app.settings.homeMode == .ysf {
            return hotspot.state == .online && !app.settings.ysfCallsign.isEmpty
        }
        // 组呼要有通话组号，单呼要有对方 DMR ID——总之 `pttDestination` 得大于 0。
        return hotspot.state == .online && app.settings.pttDestination > 0
    }

    private var pttStatusText: String {
        // YSF 没有通话组：目的固定是 ALL，提示里也不该出现 TG 号。
        if app.settings.homeMode == .ysf {
            if hotspot.isTransmitting {
                return String(format: "正在发射 %.1f 秒", hotspot.txSeconds) + " · YSF"
            }
            if pttDenied {
                return "麦克风没授权：设置 → EasyDMR → 麦克风"
            }
            if hotspot.state != .online {
                return "连上反射器后才能发射"
            }
            if app.settings.ysfCallsign.isEmpty {
                return "先在设置里填呼号，YSF 才能发射"
            }
            return "按住说话 · YSF（\(app.settings.ysfCallsign)）"
        }

        if hotspot.isTransmitting {
            return String(format: "正在发射 %.1f 秒", hotspot.txSeconds)
                + " · " + app.settings.destinationText()
        }
        if pttDenied {
            return "麦克风没授权：设置 → EasyDMR → 麦克风"
        }
        if hotspot.state != .online {
            return "连上服务器后才能发射"
        }
        // 组呼 / 单呼缺的东西不一样，提示也得分开写，否则「去选通话组」会误导单呼用户。
        if app.settings.isPrivateCall {
            guard app.settings.privateId > 0 else {
                return "先在上面填对方的 DMR ID"
            }
            return "按住说话 · 单呼 \(app.settings.privateId)"
        }
        if app.settings.talkgroup <= 0 {
            return "先在连接按钮上方选一个通话组"
        }
        return "按住说话 · TG \(app.settings.talkgroup)"
    }

    private func pressPtt() {
        guard !pttPressed else { return }
        // PTT 用高优先级拖拽手势，列表上那个「点空白收键盘」的观察手势收不到这里；
        // 手指已经落在 PTT 上就说明不想再输号码了，顺手收掉键盘。
        dismissKeyboard()
        guard canTransmit else { return }
        pttPressed = true
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()

        // 已经授权过就**同步**开麦：不绕 async，也不等下一个 runloop 周期。
        // 麦克风权限只在第一次需要问，常态下这条分支直接生效。
        if PttMicrophone.permissionGranted {
            startTransmitting()
            return
        }

        Task { @MainActor in
            let granted = await PttMicrophone.requestPermission()
            guard granted else {
                pttPressed = false
                pttDenied = true
                return
            }
            pttDenied = false
            // 权限弹框期间用户可能已经松手了，这时候不该再开麦
            guard pttPressed else { return }
            startTransmitting()
        }
    }

    /// 真正开始发射。目的地址在按下的那一刻取一次：
    /// 这之后用户改设置也不影响正在发的这一句。
    private func startTransmitting() {
        hotspot.beginPtt(destination: app.settings.pttDestination,
                         isPrivate: app.settings.isPrivateCall)
        if !hotspot.isTransmitting {
            // 开麦失败（没权限 / 没有可用输入）时把按钮状态收回来，
            // 否则会一直显示成按下却不发射。
            pttPressed = false
        }
    }

    private func releasePtt() {
        guard pttPressed || hotspot.isTransmitting else { return }
        pttPressed = false
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        hotspot.endPtt()
    }

    // MARK: - 当前讲话人

    private var speakerSection: some View {
        Section {
            // 只有真有人说话时才起这个每秒刷新的计时器，空闲时不留一个空转的 TimelineView。
            if let item = currentSpeakerItem {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    speakerRow(item, at: context.date)
                }
                .cardRow()
            } else {
                waitingRow
            }
        } header: {
            Text("当前讲话人")
        }
    }

    /// 「当前讲话人」和「刚刚结束」共用同一张卡片，版式照抄日志页：
    /// 左边三行（呼号+姓名 / 通话组 + 时隙 / 地区），右边时间与时长。
    /// 差别只有一处——正在说话的那张卡片，时长染成主题色，下面多一条实时电平。
    private func speakerRow(_ item: SpeakerItem, at now: Date) -> some View {
        let speaker = item.speaker
        let speaking = item.isSpeaking(at: now)
        // YSF 的源是呼号（协议里没有数字 ID），本地库里查不到，直接用协议带下来的那个。
        let isYsfSpeaker = !(speaker.name ?? "").isEmpty
        let name = isYsfSpeaker ? nil : speakerName(speaker.src)
        let place = isYsfSpeaker ? nil : speakerPlace(speaker.src)

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                // 第一行：呼号 + 姓名
                HStack(spacing: 6) {
                    Text(isYsfSpeaker ? (speaker.name ?? "") : speakerCallsign(speaker.src))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    if let name {
                        Text(name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // 第二行：通话组（Homebrew 下再带时隙）
                Text(speakerChannel(speaker))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // 第三行：地区
                if let place {
                    Text(place)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 4) {
                Text(Fmt.clock.string(from: speaker.startedAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Text(Fmt.duration(speaker.talkTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(speaking ? Color.accentColor : Color.secondary)

                if speaking {
                    LevelMeter(level: Double(hotspot.voiceLevel))
                        .frame(width: 44, height: 6)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .animation(.easeInOut(duration: 0.2), value: speaking)
        // 本地库里没有的 ID 才联网补查一次；已知的会被 CallsignDirectory 直接跳过。
        .onAppear { callsigns.request(speaker.src) }
    }

    private var waitingRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.wave.2")
                .foregroundStyle(.secondary)
            Text(hotspot.state == .online ? "等待通话" : "未连接")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - 通话记录合并

    private var currentSpeakerItem: SpeakerItem? {
        hotspot.currentSpeaker.map { SpeakerItem(speaker: $0, isLive: true) }
    }

    /// 「刚刚结束」的列表，两条规则：
    ///
    /// - 同一个 `src→dst→slot` 只保留**最新**一条（核心里的 `calls` 是「新插入在 0」，
    ///   所以第一次遇到的就是最新的）。
    /// - 和当前讲话人重复的那条直接跳过——它已经显示在最上面了，不能出现两份。
    private var recentSpeakerItems: [SpeakerItem] {
        var seen = Set<String>()
        if let current = currentSpeakerItem { seen.insert(current.id) }

        var items: [SpeakerItem] = []
        for call in hotspot.recentCalls {
            let item = SpeakerItem(call: call)
            guard seen.insert(item.id).inserted else { continue }
            items.append(item)
            if items.count >= 8 { break }
        }
        return items
    }

    /// 有呼号显示呼号，没有就退回数字 ID——宁可显示得糙一点，也不能空着。
    private func speakerCallsign(_ id: Int) -> String {
        callsigns.callsign(for: id) ?? "\(id)"
    }

    /// 本地库里的姓名；没有就返回 nil，那一行只显示呼号。
    private func speakerName(_ id: Int) -> String? {
        guard let name = callsigns.user(for: id)?.fullName, !name.isEmpty else { return nil }
        return name
    }

    /// 本地库里的地区（国家/省/市拼好的那一行）。
    private func speakerPlace(_ id: Int) -> String? {
        guard let place = callsigns.user(for: id)?.placeText, !place.isEmpty else { return nil }
        return place
    }

    /// `通话组名 · TG 46001 · TS2`；单呼另说。和日志页的 `channelText` 同一套写法。
    private func speakerChannel(_ speaker: ActiveSpeaker) -> String {
        var parts: [String] = []

        // YSF：目的就是呼号（组呼固定是 ALL），没有通话组号也没有时隙。
        if let channel = speaker.channel, !channel.isEmpty {
            return "YSF · \(channel)"
        }

        if speaker.isPrivate {
            parts.append("单呼 \(speaker.src) → \(speaker.dst)")
        } else if let name = app.name(for: speaker.dst) {
            parts.append("\(name) · TG \(speaker.dst)")
        } else {
            parts.append("TG \(speaker.dst)")
        }

        // ODTP 没有时隙概念，标个 TS2 只会误导
        if app.settings.linkProtocol == .homebrew {
            parts.append("TS\(speaker.slot)")
        }

        return parts.joined(separator: " · ")
    }

    // MARK: - 语音（开关在设置页，这里只留状态和快捷开关）

    /// 连接时间右边那个静音按钮：改的是和设置 → 语音 → 「语音播放」同一个开关。
    private func toggleAudio() {
        app.settings.audioEnabled.toggle()
        hotspot.applyAudioPreference(app.settings)
    }

    private var audioIcon: String {
        if !app.settings.audioEnabled { return "speaker.slash" }
        return hotspot.isVoicePlaying ? "waveform" : "speaker.wave.1"
    }

    /// 电平表/读数的实际输入：没在放音就当作 0，避免上一句话的峰值一直挂在表上。
    private var displayLevel: Double {
        hotspot.isVoicePlaying ? smoothedLevel : 0
    }

    /// 交给 `SignalReport` 折算成 `59` / `59+20` 这种报法。
    private var signalReport: SignalReport {
        SignalReport(level: displayLevel)
    }

    // MARK: - 辅助

    private var isConnectedOrBusy: Bool {
        hotspot.state == .online || hotspot.state.isBusy
    }

    private var buttonTitle: String {
        isConnectedOrBusy ? "断开连接" : "连接"
    }

    private var statusColor: Color {
        switch hotspot.state {
        case .online:
            return .green
        case .offline:
            return .gray.opacity(0.5)
        case .failed:
            return .red
        default:
            return .orange
        }
    }

    private func uptimeText(at date: Date) -> String {
        guard let since = hotspot.connectedSince else { return "--:--" }
        return Fmt.duration(date.timeIntervalSince(since))
    }

    private func toggleConnection() {
        // 连接 / 断开是要动电台的动作，号码已经敲完了，键盘留着只会挡住状态。
        dismissKeyboard()
        if isConnectedOrBusy {
            app.disconnect()
        } else {
            app.connect()
        }
    }

    /// 收起键盘。
    ///
    /// 单呼号码框用的是数字键盘，没有「完成」键，只能主动取消第一响应者；
    /// 这里不追踪具体是哪个框，收掉当下那个就对了（页面上同时只有一个输入框）。
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

// MARK: - 号码框位置

/// 单呼号码框上报自己在屏幕（全局）坐标系里的位置（点框外收键盘时用来放过框内的点击）。
private struct PrivateFieldFrameKey: PreferenceKey {
    // 用 `let` 而不是 `var`：这个值从不参与归并，写死零就够了，也免得将来开严格并发时告警。
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - 一条通话记录

/// 「当前讲话人」和「刚刚结束」共用的一条记录。
///
/// `LiveCall` 和 `ActiveSpeaker` 的字段几乎一样，显示也要求完全一致，
/// 所以先统一成这个结构再交给同一个行视图渲染。
private struct SpeakerItem: Identifiable, Equatable {
    let speaker: ActiveSpeaker
    /// 是不是最上面那行「当前讲话人」（只有它会每秒刷新、显示实时电平）。
    let isLive: Bool
    /// 同一个 `src→dst→slot` 只能出现一次，和核心里的 `LiveCall.id` 是同一个格式。
    let id: String

    init(speaker: ActiveSpeaker, isLive: Bool) {
        self.speaker = speaker
        self.isLive = isLive
        self.id = "\(speaker.src)-\(speaker.dst)-\(speaker.slot)"
    }

    init(call: LiveCall) {
        self.init(speaker: ActiveSpeaker(src: call.src,
                                         dst: call.dst,
                                         slot: call.slot,
                                         isPrivate: call.isPrivate,
                                         startedAt: call.startedAt,
                                         lastVoiceAt: call.updatedAt,
                                         endedAt: call.isActive ? nil : call.updatedAt),
                  isLive: false)
    }

    func isSpeaking(at now: Date) -> Bool {
        isLive && speaker.isSpeaking(at: now)
    }
}

// MARK: - 指标

struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 信号报告

/// 把 0…1 的音频峰值折算成业余无线电的信号报告（RST 里 R+S 那两位）。
///
/// 刻度照 S 表的规矩：S1…S9 每级 6 dB，S9 以上报「S9 + N dB」；
/// 数字语音的可读度恒为 5，所以 S9 就是 `59`，S9 以上是 `59+10` / `59+20`……
///
/// 参考点取 S9 = -30 dBFS：AMBE 解出来的语音峰值大多在 0.03…0.5 之间，
/// 正常说话落在 `59` 上下，声音顶满能到 `59+20` 以上。
struct SignalReport: Equatable {
    /// 低于这个值当作没有信号，读数显示占位符。
    private static let noiseFloor: Double = 0.0005
    /// S9 对应的电平（dBFS）。
    private static let s9dBFS: Double = -30
    /// S 表每级 6 dB，业余无线电的通行约定。
    private static let dBBetweenSUnits: Double = 6

    /// 0 = 无信号，1…9 = S1…S9。
    let sUnits: Int
    /// S9 以上的 dB 数，按真实表盘的 10/20/30/40/60 归一档。
    let overDB: Int

    init(level: Double) {
        guard level > Self.noiseFloor else {
            sUnits = 0
            overDB = 0
            return
        }

        // 峰值是线性的，S 表是 dB 刻度，先换成 dBFS（≤ 0）。
        let dbfs = 20 * log10(level)
        let units = 9 + (dbfs - Self.s9dBFS) / Self.dBBetweenSUnits

        if units <= 9 {
            sUnits = max(1, min(9, Int(units.rounded(.down))))
            overDB = 0
        } else {
            sUnits = 9
            overDB = Self.nominalOver((units - 9) * Self.dBBetweenSUnits)
        }
    }

    var hasSignal: Bool { sUnits > 0 }

    /// `59` / `59+20` / `57`；没信号时 `—`。
    var text: String {
        guard hasSignal else { return "—" }
        return overDB > 0 ? "59+\(overDB)" : "5\(sUnits)"
    }

    /// 表盘只有 10/20/30/40/60 这几档，中间值报下面那一档。
    private static func nominalOver(_ db: Double) -> Int {
        switch db {
        case ..<5: return 0
        case ..<15: return 10
        case ..<25: return 20
        case ..<35: return 30
        case ..<50: return 40
        default: return 60
        }
    }
}

// MARK: - 电平表

/// 分段电平指示，跟着解码器每个包输出的峰值跳动。
/// 首页那张表整行铺开，所以段数可以调多（默认 8 段给「当前讲话人」里的小表用）。
struct LevelMeter: View {
    let level: Double
    var segments: Int = 8

    var body: some View {
        let filled = Self.fraction(of: level)
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { index in
                let threshold = Double(index + 1) / Double(max(1, segments))
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(filled >= threshold ? color(at: index) : Color.secondary.opacity(0.15))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityLabel("电平 \(Int(level * 100))%")
    }

    /// 峰值是线性的、听感是 dB 的：整条表按 -60…0 dBFS 铺满，
    /// 这样表的位置和上方 `59` / `59+20` 的档位对得上（-30 dBFS 正好一半，也就是 S9）。
    private static func fraction(of level: Double) -> Double {
        guard level > 0.0005 else { return 0 }
        let dbfs = 20 * log10(min(1, level))
        return min(1, max(0, (dbfs + 60) / 60))
    }

    private func color(at index: Int) -> Color {
        if index >= segments - 1 { return .red }
        if index >= segments - 3 { return .orange }
        return .green
    }
}

// MARK: - 单呼目的地址输入框

/// 首页「组呼 / 单呼」切到单呼时，顶替通话组选择器的那一格。
///
/// 版式故意做成和 `TalkgroupPickerField` 的触发器一模一样（同高 44、同底色、
/// 同行内边距）：切换模式时这一格只是内容变了，位置和高度都不动，看着不会跳。
///
/// 输入即生效——没有键盘的「确定」键可靠可用（数字键盘没有回车），
/// 所以每敲一个字符就校验一次，合法就写回 `settings.privateId`，
/// 不合法（空 / 超 24 位）就保持原值不动，只在下面标红提示。
private struct PrivateIdField: View {
    @Binding var id: Int

    @State private var draft: String
    @FocusState private var focused: Bool

    init(id: Binding<Int>) {
        _id = id
        // 初值从设置里取一次：切回单呼时能看到上次填的号码。
        _draft = State(initialValue: id.wrappedValue > 0 ? String(id.wrappedValue) : "")
    }

    /// 只留数字：粘贴进来带空格 / `=` 的情况很常见。
    private var digits: String {
        draft.filter { $0.isNumber }
    }

    private var parsed: Int? {
        guard let value = Int(digits), Settings.privateIdRange.contains(value) else { return nil }
        return value
    }

    private var hint: String {
        if digits.isEmpty { return "对方 DMR ID" }
        if parsed == nil { return "号码要在 1…16777215 之间" }
        return "单呼 · 目的地址 \(digits)"
    }

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                TextField("对方 DMR ID", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .keyboardType(.numberPad)
                    .focused($focused)
                    .submitLabel(.done)
                    .lineLimit(1)

                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(parsed == nil && !digits.isEmpty ? Color.red : Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            // 有内容时给一个一键清空，省得长按删数字。
            if !digits.isEmpty {
                Button {
                    draft = ""
                    id = 0
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空目的地址")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Color(uiColor: .secondarySystemFill),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onChange(of: draft) { newValue in
            // 先把非数字字符滤掉（粘贴带进来的空格 / 分隔符），改完让它再走一遍这里。
            let clean = newValue.filter { $0.isNumber }
            if clean != newValue {
                draft = clean
                return
            }
            // 合法就落盘；清空就归零；中间态（比如刚敲一位就超范围）
            // 保留上一个合法值，PTT 不会因为正在输入而变成不可用。
            if let value = parsed {
                id = value
            } else if clean.isEmpty {
                id = 0
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("单呼目的地址")
        .accessibilityValue(parsed.map { "DMR ID \($0)" } ?? "未填写")
    }
}

// MARK: - 卡片行

private extension View {
    /// 卡片行：去掉分组列表默认的底色、内缩和分隔线，让行内部自己画的圆角卡片透出来。
    /// 和日志页 `CallLogView.row(for:)` 是同一套尺寸（上下各留 4pt 的空隙当卡片间距）。
    func cardRow() -> some View {
        listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
