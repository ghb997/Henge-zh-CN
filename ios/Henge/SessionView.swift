// Simplified Chinese translation, 2026-11-09.
import SwiftUI
import GameController

/// A running Mac. Upright, its screen sits above a trackpad; on its side the screen fills the device
/// and is its own trackpad. Zoomed in, the screen fills the device either way and follows the pointer.
/// A keyboard, trackpad or mouse attached to an iPad works throughout.
struct SessionView: View {
    let mac: VirtualMac
    let close: () -> Void

    @StateObject private var display = DisplayRouter()
    @State private var error: String?
    @State private var state: Int32 = 0
    @State private var cpusOn: Int32 = 0
    @State private var userCode = false
    @State private var blocksPerSecond: Double = 0
    @State private var framesOut: UInt64 = 0
    @State private var framesIn: UInt64 = 0
    @State private var log: [String] = []
    @State private var started = Date()
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    @AppStorage("henge.cpus") private var cpus = 4
    @AppStorage("henge.matchScreenColors") private var matchScreenColors = true
    @AppStorage("henge.display.brightness") private var screenBrightness = 1.0
    @AppStorage("henge.cursor.scale") private var cursorScale = Device.isPad ? 1 : 3
    @AppStorage("henge.cursor.sharp") private var sharpCursor = true
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3

    @State private var typing = false
    @State private var zoomed = false
    @State private var showDetails = false
    @State private var controlsHidden = false
    @State private var showRevealHint = false
    @State private var pointerRefused = false
    @AppStorage("henge.controls.hintsShown") private var revealHintsShown = 0
    /// Once per install: macOS's moving wallpapers and aerial screen saver are video, decoded by the emulated
    /// CPUs (a phone ran about 30% faster with a still one).
    @AppStorage("henge.tips.stillWallpaperShown") private var stillWallpaperTipShown = false
    @State private var showWallpaperTip = false
    @State private var confirmStop = false
    @State private var zoomCentre = CGPoint(x: 0.5, y: 0.5) // where the zoomed view is, 0...1 of the Mac's screen
    @State private var map: UIImage?
    @State private var zoomFollowing: Task<Void, Never>?
    @State private var helperRunning = false
    @State private var shown = CGSize(width: 0.5, height: 0.5) // how much of the Mac's screen the zoomed view shows
    @Environment(\.scenePhase) private var scenePhase


    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            let landscape = full.width > full.height
            let layout = Layout(full: full, insets: insets, landscape: landscape, zoomed: zoomed, typing: typing, centre: zoomCentre, aspect: mac.aspect)
            ZStack(alignment: .topLeading) {
                (landscape || zoomed ? Color.black : Desk.page)
                // One view in every layout: it holds the layer the engine draws into.
                BootDisplay(display: display, role: .device)
                    .opacity(display.isExternal ? 0 : 1)
                    .overlay {
                        if display.isExternal {
                            VStack(spacing: 8) {
                                Image(systemName: "display").font(.largeTitle)
                                Text("Mac 正在外接显示器上显示").font(.headline)
                                Text("请使用触控板、键盘或已连接的鼠标。")
                                    .font(.subheadline)
                            }
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(width: layout.screen.width, height: layout.screen.height)
                    .clipShape(RoundedRectangle(cornerRadius: layout.fillsPhone ? 0 : 15, style: .continuous))
                    .overlay {
                        if !layout.fillsPhone {
                            RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                        }
                    }
                    .position(x: layout.screen.midX, y: layout.screen.midY)
                Trackpad()
                    .frame(width: layout.touch.width, height: layout.touch.height)
                    .position(x: layout.touch.midX, y: layout.touch.midY)
                if !layout.fillsPhone {
                    uprightControls(layout)
                } else {
                    floatingControls(layout)
                }
                if pointerRefused && !showRevealHint {
                    Label("请将 Henge 切换为全屏，以使用触控板或鼠标控制 Mac", systemImage: "cursorarrow.rays")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .deskGlass(in: Capsule())
                        .position(x: full.width / 2, y: insets.top + 40)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if showRevealHint {
                    Label("三指轻点可显示控制栏", systemImage: "hand.tap")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .deskGlass(in: Capsule())
                        .position(x: full.width / 2, y: insets.top + 40)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if showWallpaperTip && !showRevealHint && !pointerRefused {
                    Label("为提高速度，请为此 Mac 设置静态墙纸，并在系统设置中将屏幕保护程序设为“永不”。", systemImage: "speedometer")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: min(full.width - 40, 520))
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .deskGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .position(x: full.width / 2, y: insets.top + 56)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
                if let error { errorCard(error, layout) }
                KeyboardCatcher(active: $typing).frame(width: 0, height: 0)
            }
            .frame(width: full.width, height: full.height)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.25), value: zoomed)
            .animation(.easeInOut(duration: 0.25), value: typing)
            .animation(.easeInOut(duration: 0.25), value: controlsHidden)
            .animation(.easeInOut(duration: 0.25), value: showRevealHint)
            .animation(.easeInOut(duration: 0.25), value: showWallpaperTip)
            .onReceive(NotificationCenter.default.publisher(for: UIPointerLockState.didChangeNotification)) { _ in
                pointerRefused = PointerLock.refused
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidConnect)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pointerRefused = PointerLock.refused }
            }
            .onReceive(NotificationCenter.default.publisher(for: Trackpad.threeFingerTap)) { _ in
                controlsHidden = false
                showRevealHint = false
            }
            .onAppear { shown = layout.shown }
            .onChange(of: layout.shown) { shown = $0 }
        }
        .statusBarHidden(zoomed || Device.isPad)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showDetails) { details }
        .confirmationDialog("关闭 \(mac.name)？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("关机", role: .destructive) { finish() }
        } message: {
            Text("这将立即关闭 Mac，所有未保存的内容都会丢失。")
        }
        .onChange(of: zoomed) { on in
            zoomFollowing?.cancel()
            zoomFollowing = on ? Task { await followPointer() } : nil
        }
        .onChange(of: pointerNeeded) { PointerLock.set(!$0) }
        .onChange(of: scenePhase) { phase in
            guard phase != .active else {
                display.refresh()
                return
            }
            HardwareKeys.releaseAll()
            HardwareMouse.shared.releaseButtons()
        }
        .onChange(of: showDetails) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onChange(of: confirmStop) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            HardwareMouse.shared.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            zoomFollowing?.cancel()
            StickyKeys.shared.releaseAll()
            HardwareKeys.releaseAll()
            HardwareMouse.shared.stop()
        }
        .modifier(ExternalMacDisplayModifier(presentation: MacPresentation(display: display, aspect: mac.aspect)))
        .task { await run() }
        .task { await Sharing.followMacClipboard() }
    }

    /// When there is something of the app's to point at, iPadOS gets its own pointer back.
    private var pointerNeeded: Bool { showDetails || confirmStop || error != nil }

    // MARK: Layout

    /// Where everything goes, in points from the device's top left corner.
    private struct Layout {
        let screen: CGRect
        let touch: CGRect     // what is a trackpad besides the pad itself
        let fillsPhone: Bool
        let toolsY: CGFloat
        let pad: CGRect
        let insets: EdgeInsets
        var barY: CGFloat?    // where the controls go in the space beside the screen, if it has room for them

        var shown: CGSize {
            CGSize(width: min(touch.width / max(screen.width, 1), 1), height: min(touch.height / max(screen.height, 1), 1))
        }

        init(full: CGSize, insets: EdgeInsets, landscape: Bool, zoomed: Bool, typing: Bool, centre: CGPoint, aspect: CGFloat) {
            self.insets = insets
            let big = full.height >= 600 // an iPad on its side, or a window on one
            if zoomed {
                // Upright, as tall as the device. On its side, bigger than it fits: a big screen needs less.
                let height = landscape ? full.height * (big ? 1.5 : 2) : max(full.height - insets.bottom, full.width / aspect)
                let width = height * aspect
                let x = min(0, max(full.width - width, full.width / 2 - centre.x * width))
                let y = min(0, max(full.height - height, full.height / 2 - centre.y * height))
                screen = CGRect(x: x, y: y, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else if landscape, big {
                // Room to keep the controls off the Mac's menu bar, and the Mac above the on-screen keyboard.
                let bar: CGFloat = 62
                let room = typing ? full.height - insets.bottom - insets.top - bar - 8 : full.height
                // An iPad keeps clear of its side insets; a big iPhone (iPhone Duo) fills edge to edge.
                let side = Device.isPad ? 2 * max(insets.leading, insets.trailing) : 0
                let height = max(min(room, (full.width - side) / aspect), 200)
                let width = height * aspect
                let y = typing ? insets.top + bar : (full.height - height) / 2
                screen = CGRect(x: (full.width - width) / 2, y: y, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
                if y - insets.top >= 54 { barY = insets.top + (y - insets.top) / 2 }
            } else if landscape {
                // Edge to edge. Phones wider than the Mac fill the height with room to spare beside the
                // Dynamic Island; a squarer phone (iPhone Duo) fills all of it, island and corners included.
                let height = min(full.height, full.width / aspect)
                let width = height * aspect
                screen = CGRect(x: (full.width - width) / 2, y: (full.height - height) / 2, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else {
                let width = full.width - 16
                let height = width / aspect
                screen = CGRect(x: 8, y: insets.top + 6, width: width, height: height)
                touch = screen
                fillsPhone = false
                toolsY = screen.maxY + 10
                let top = typing ? screen.maxY + 8 : toolsY + 54 + 10
                let bottom = full.height - insets.bottom - (typing ? 8 : 0)
                pad = CGRect(x: 8, y: top, width: width, height: max(bottom - top, 60))
            }
        }
    }

    // MARK: Upright

    @ViewBuilder private func uprightControls(_ layout: Layout) -> some View {
        if !typing && !controlsHidden {
            HStack {
                tool("eye.slash", "隐藏控制栏") { hideControls() }
                Spacer()
                tool("keyboard", "键盘") { typing = true }
                Spacer()
                pasteTool
                Spacer()
                tool("plus.magnifyingglass", "放大") { zoomed = true }
                Spacer()
                tool("info.circle", "详情") { showDetails = true }
                Spacer()
                tool("power", "关机", tint: Desk.bad) { stopTapped() }
            }
            .padding(.horizontal, 22)
            .frame(width: layout.pad.width, height: 54)
            .background(Desk.card, in: Capsule())
            .overlay(Capsule().stroke(Desk.hairline, lineWidth: 0.5))
            .position(x: layout.pad.midX, y: layout.toolsY + 27)
            .transition(.opacity)
        }
        trackpadPanel(layout)
    }

    private func trackpadPanel(_ layout: Layout) -> some View {
        let compact = layout.pad.height < 260
        return VStack(spacing: 0) {
            ZStack {
                Trackpad()
                if compact {
                    Text("触控板").font(.system(size: 14)).foregroundStyle(Desk.faint).allowsHitTesting(false)
                } else {
                    VStack(spacing: 6) {
                        hint("滑动", "移动指针")
                        hint("轻点", "单击")
                        hint("长按后拖动", "拖移项目")
                        hint("双指滑动", "滚动页面")
                    }
                    .allowsHitTesting(false)
                }
            }
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            HStack(spacing: 0) {
                MouseButton(title: "左键单击", button: 0)
                Rectangle().fill(Desk.hairline).frame(width: 0.5)
                MouseButton(title: "右键单击", button: 1)
            }
            .frame(height: compact ? 50 : 70)
        }
        .background(Desk.card)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Desk.hairline, lineWidth: 0.5))
        .frame(width: layout.pad.width, height: layout.pad.height)
        .position(x: layout.pad.midX, y: layout.pad.midY)
    }

    private func hint(_ strong: String, _ rest: String) -> some View {
        (Text(strong).foregroundColor(Desk.dim).fontWeight(.semibold) + Text(" \(rest)").foregroundColor(Desk.faint))
            .font(.system(size: 15))
    }

    /// The system's paste button: iOS asks no permission for it, as it would if the app read the clipboard itself.
    private var pasteTool: some View {
        PasteButton(payloadType: String.self) { texts in
            if let text = texts.first { Sharing.paste(text) }
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .tint(Desk.raised)
    }

    /// Hides the session's controls; three fingers on the screen bring them back. The first few times say so.
    private func hideControls() {
        controlsHidden = true
        typing = false
        guard revealHintsShown < 3 else { return }
        revealHintsShown += 1
        showRevealHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showRevealHint = false }
    }

    private func tool(_ symbol: String, _ label: String, tint: Color = Desk.text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: Filling the phone

    @ViewBuilder private func floatingControls(_ layout: Layout) -> some View {
        let landscape = layout.touch.width > layout.touch.height
        let top = layout.insets.top + (landscape ? 8 : 6)
        let pill = HStack(spacing: 4) {
            tool("eye.slash", "隐藏控制栏", tint: .white) { hideControls() }
            tool("keyboard", "键盘", tint: .white) { typing.toggle() }
            pasteTool
            tool(zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass", zoomed ? "缩小" : "放大", tint: zoomed ? Desk.accentLight : .white) { zoomed.toggle() }
            tool("info.circle", "详情", tint: .white) { showDetails = true }
            Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 22).padding(.horizontal, 4)
            tool("power", "关机", tint: Desk.bad) { stopTapped() }
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .deskGlass(in: Capsule())
        if controlsHidden {
            EmptyView()
        } else if let barY = layout.barY {
            pill.position(x: layout.touch.midX, y: barY)
        } else if landscape || typing {
            pill.position(x: layout.touch.midX, y: top + 25)
        } else {
            pill.position(x: layout.touch.midX, y: layout.touch.height - layout.insets.bottom - 34)
        }
        if zoomed { zoomMap(layout) }
    }

    /// The whole screen, small, with where the zoomed view is on it.
    private func zoomMap(_ layout: Layout) -> some View {
        let width: CGFloat = 112, height = width / mac.aspect
        let viewW = min(layout.touch.width / layout.screen.width, 1) * width
        let viewH = min(layout.touch.height / layout.screen.height, 1) * height
        let left = (-layout.screen.minX / layout.screen.width) * width
        let top = (-layout.screen.minY / layout.screen.height) * height
        return ZStack(alignment: .topLeading) {
            Color.black
            if let map { Image(uiImage: map).resizable() }
            RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1.5)
                .frame(width: viewW, height: viewH)
                .offset(x: left, y: top)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(3)
        .deskGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .position(x: layout.touch.width - width / 2 - 15, y: layout.insets.top + height / 2 + 20)
        .allowsHitTesting(false)
    }

    /// Keeps the pointer in view: the view moves when the pointer nears its edge.
    private func followPointer() async {
        var tick = 0
        while !Task.isCancelled {
            var x: Int32 = 0, y: Int32 = 0
            if henge_vm_pointer(&x, &y) == 0 {
                moveZoom(toward: CGPoint(x: CGFloat(x) / CGFloat(mac.screen.width), y: CGFloat(y) / CGFloat(mac.screen.height)))
            }
            if tick % 60 == 0, let image = MacPreview.capture(width: 224, height: Int(224 / mac.aspect)) { map = UIImage(cgImage: image) }
            tick += 1
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    private func moveZoom(toward p: CGPoint) {
        // How much of the screen the view shows, and a margin inside that.
        let shownX = shown.width, shownY = shown.height
        let reachX = shownX * 0.3, reachY = shownY * 0.3
        var c = zoomCentre
        if p.x < c.x - reachX { c.x = p.x + reachX } else if p.x > c.x + reachX { c.x = p.x - reachX }
        if p.y < c.y - reachY { c.y = p.y + reachY } else if p.y > c.y + reachY { c.y = p.y - reachY }
        c.x = min(max(c.x, shownX / 2), 1 - shownX / 2)
        c.y = min(max(c.y, shownY / 2), 1 - shownY / 2)
        guard c != zoomCentre else { return }
        withAnimation(.linear(duration: 0.08)) { zoomCentre = c }
    }

    // MARK: Status

    private func errorCard(_ text: String, _ layout: Layout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("无法启动此 Mac").font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 14)).foregroundStyle(Desk.dim)
            Button("关闭") { close() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
        }
        .padding(18)
        .frame(width: min(layout.touch.width, 390) - 32, alignment: .leading)
        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .position(x: (layout.fillsPhone ? layout.touch.midX : layout.pad.midX), y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
    }

    private var phase: String {
        switch state {
        case 0: return error == nil ? "正在启动…" : "未启动"
        case 1: return userCode ? "macOS 正在运行" : "正在引导"
        default: return "已停止（\(String(cString: henge_vm_exit_reason()))）"
        }
    }

    private var details: some View {
        NavigationStack {
            List {
                Section(phase) {
                    LabeledContent("已启用 CPU", value: "\(cpusOn) / \(cpus)")
                    LabeledContent("温度", value: Self.thermalLabel(thermalState))
                    LabeledContent("翻译块速度", value: String(format: "%.1f 百万块/秒", blocksPerSecond / 1e6))
                    LabeledContent("网络帧", value: "发送 \(framesOut)，接收 \(framesIn)")
                    LabeledContent("运行时间", value: "\(Int(Date().timeIntervalSince(started))) 秒")
                }
                Section("显示") {
                    Toggle("色彩匹配", isOn: $matchScreenColors)
                    LabeledContent("亮度", value: "\(Int(screenBrightness * 100))%")
                    Slider(value: $screenBrightness, in: 0.4...1)
                    Text("此亮度设置仅调节 Mac 画面。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("指针") {
                    Picker("大小", selection: $cursorScale) {
                        Text("1×").tag(1)
                        Text("2×").tag(2)
                        Text("3×").tag(3)
                    }
                    .pickerStyle(.segmented)
                    Toggle("锐化边缘", isOn: $sharpCursor)
                    LabeledContent("滚动速度", value: String(format: "%.1f×", scrollSpeed))
                    Slider(value: $scrollSpeed, in: 0.1...1.5)
                    Text("Mac 提供的指针图像较小，放大后可能模糊。在 iPad 上，1 倍大小最清晰。滚动速度更改会立即生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("共享") {
                    LabeledContent("剪贴板与文件夹", value: helperRunning ? "已开启" : "未设置")
                    if !helperRunning {
                        Button("输入设置命令") {
                            showDetails = false
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                await Sharing.typeSetUpCommand()
                            }
                        }
                    }
                    Text(helperRunning
                         ? "将文件放入“文件”中的 Henge/Shared，即可在此 Mac 主文件夹下的 Henge 文件夹中看到它们。在 Mac 上复制的内容也会同步到此设备，粘贴按钮可将此设备的内容粘贴到 Mac。"
                         : "每台 Mac 仅需设置一次。在 Mac 上打开“终端”，轻点此按钮，然后按回车键。当 macOS 询问是否允许 henge-agent 访问本地网络时，选择“允许”。此操作会输入 \(Sharing.setUpCommand)，需要将 Mac 的键盘布局设为“美国”。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("精简 macOS 特效") {
                    Button("输入精简特效命令") {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.lightenCommand)
                        }
                    }
                    Button("输入撤销命令") {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.unlightenCommand)
                        }
                    }
                    Text("关闭窗口和程序坞动画、桌面小组件、屏幕保护程序及动态墙纸，可减轻模拟 CPU 的绘制负担。在 Mac 上打开“终端”，轻点按钮并按回车键，然后退出登录并重新登录。还可以在 Mac 的“系统设置”→“辅助功能”中开启“减弱动态效果”和“降低透明度”。撤销命令可恢复除墙纸外的设置。需要将 Mac 的键盘布局设为“美国”。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("日志") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.suffix(30).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("详情")
            .navigationBarTitleDisplayMode(.inline)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Running

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "正常"
        case .fair: return "温热"
        case .serious: return "过热，性能已降低"
        case .critical: return "严重过热"
        @unknown default: return "未知"
        }
    }

    private func run() async {
        let ram = GuestMemory.prepare(mac)
        HengeLog.log("session", "available memory \(henge_available_memory() >> 20) MB")
        guard ram >= 1024 else {
            error = "无法为此 Mac 分配内存，需要数 GB 的可用存储空间。"
            return
        }
        var buffer = [CChar](repeating: 0, count: 256)
        Sharing.prepare()
        EngineTuning.apply()
        henge_vm_set_display(UInt32(mac.screen.width), UInt32(mac.screen.height))
        if mac.isRetina {
            henge_vm_set_display_mm(UInt32(Device.retinaMM.width), UInt32(Device.retinaMM.height))
        } else {
            henge_vm_set_display_mm(0, 0)
        }
        HengeLog.log("session", "screen \(mac.screen.width)x\(mac.screen.height) retina \(mac.isRetina)")
        let rc = henge_vm_boot(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, mac.seed, ram, Int32(cpus), &buffer, buffer.count)
        if rc != 0 {
            error = String(cString: buffer)
            return
        }
        started = Date()
        var used = mac
        used.lastUsed = started
        Machines.shared.update(used)
        var lastBlocks = henge_vm_blocks()
        var lastTime = Date()
        var lastGPUFrames = henge_vm_gpu_frames()
        var tick = 0
        while !Task.isCancelled {
            state = henge_vm_state()
            cpusOn = henge_vm_cpus_on()
            userCode = userCode || henge_vm_guest_el0() != 0
            let now = Date(), blocks = henge_vm_blocks()
            blocksPerSecond = Double(blocks &- lastBlocks) / max(now.timeIntervalSince(lastTime), 0.001)
            lastBlocks = blocks
            lastTime = now
            framesOut = henge_vm_net_frames(1)
            framesIn = henge_vm_net_frames(0)
            helperRunning = Sharing.helperRunning
            log = Array(HengeLog.recentLines(200))
            let heat = ProcessInfo.processInfo.thermalState
            if heat.rawValue != thermalState.rawValue {
                thermalState = heat
                HengeLog.log("session", "thermal state: \(Self.thermalLabel(heat))")
            }
            if state == 2 { break }
            tick += 1
            if tick % 10 == 0 {
                let gpuFrames = henge_vm_gpu_frames()
                HengeLog.log("perf", "blocks/s \(String(format: "%.0f", blocksPerSecond)), GPU frames/10s \(gpuFrames &- lastGPUFrames), "
                             + "network tx \(framesOut), rx \(framesIn), thermal \(Self.thermalLabel(heat))")
                lastGPUFrames = gpuFrames
            }
            if tick == 60 && !stillWallpaperTipShown { // about when the desktop is up after a login
                stillWallpaperTipShown = true
                showWallpaperTip = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { showWallpaperTip = false }
            }
            if tick % 30 == 0 { HengeLog.logFootprint("session") } // how close to the limit, for a memory kill leaves no crash report
            if tick % 60 == 0 { MacPreview.save(for: mac) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func stopTapped() {
        if state == 1 { confirmStop = true } else { close() }
    }

    private func finish() {
        if state == 1 {
            MacPreview.saveNow(for: mac)
            henge_vm_stop()
        }
        close()
    }
}
