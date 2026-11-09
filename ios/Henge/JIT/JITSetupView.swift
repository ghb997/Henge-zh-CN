// Simplified Chinese translation, 2026-11-09.
// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// The JIT walkthrough: pick a way in, follow its numbered steps, end with JIT on.
///
/// Three ways in. Pairing on this iPhone (iOS 27) and a pairing file made on a
/// computer both lead to Built-in StikJIT and share the last two steps,
/// LocalDevVPN and enabling. StikDebug has its own short page. Presented from
/// onboarding, Settings › JIT, and whenever Start finds JIT not set up.
struct JITSetupFlow: View {
    enum Step: Hashable { case pairOnDevice, importFile, connect, enable, stikDebug, trollStore, jailbreak }

    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @State private var path: [Step] = []
    @State private var importing = false
    @Environment(\.dismiss) private var dismiss

    private var device: String { OnDevicePairing.deviceKind }

    var body: some View {
        NavigationStack(path: $path) {
            choose
                .hengeDestination(for: Step.self) { step in
                    switch step {
                    case .pairOnDevice: pairOnDevice
                    case .importFile: importFile
                    case .connect: connect
                    case .enable: enable
                    case .stikDebug: stikDebug
                    case .trollStore: trollStore
                    case .jailbreak: jailbreak
                    }
                }
        }
        .tint(Theme.accent)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .data]) { result in
            switch result {
            case .success(let url): jit.importPairingFile(url)
            case .failure(let failure):
                HengeLog.log("jit", "pairing import failed: \(failure.localizedDescription)")
            }
        }
        .onAppear {
            jit.refreshPairingStatus()
            pairing.reset()
            // A failed enable from the Library lands on the step that can fix it.
            if jit.error != nil, jit.hasPairing, jit.resolvedMethod == .builtIn {
                path = [.enable]
            }
            HengeLog.log("ui", "JIT walkthrough opened")
        }
        // Swiping the sheet away, or a copy shown from onboarding, must not
        // leave a request to show it again behind.
        .onDisappear { jit.showSetup = false }
    }

    private func close() {
        jit.showSetup = false
        dismiss()
    }

    // MARK: Choose

    private var choose: some View {
        page(symbol: "bolt.fill", title: "开启 JIT",
             subtitle: "Mac 需要能够写入并执行代码的内存。iOS 需要通过调试器授予这项权限。"
                     + "请选择在这台 \(device) 上启用 JIT 的方式。") {
            VStack(spacing: 10) {
                let builtIn = HengeBuiltInJIT.unavailableReason
                way("在此 \(device) 上配对", symbol: "iphone.radiowaves.left.and.right",
                    detail: builtIn ?? (!OnDevicePairing.isSupported ? "需要 iOS 27 或更高版本。"
                        : jit.pairingSource == .onDevice ? "已在此 \(device) 上完成配对。"
                        : "可直接在系统设置中配对，大约需要一分钟。"),
                    done: jit.pairingSource == .onDevice,
                    enabled: builtIn == nil && OnDevicePairing.isSupported) { path.append(.pairOnDevice) }
                way("使用配对文件", symbol: "doc.badge.plus",
                    detail: builtIn ?? (jit.pairingSource == .imported ? "配对文件已导入。"
                        : "导入在电脑上生成的配对文件。"),
                    done: jit.pairingSource == .imported,
                    enabled: builtIn == nil) { path.append(.importFile) }
                way("使用 StikDebug", symbol: "ant",
                    detail: JITBootstrap.isStikDebugInstalled ? "已安装 StikDebug。"
                        : "通过 StikDebug 应用启用 JIT。",
                    done: jit.method == .stikDebug) { path.append(.stikDebug) }
                way("使用 TrollStore", symbol: "sparkles",
                    detail: JITBootstrap.isTrollStoreInstalled ? "已安装 TrollStore。"
                        : "适用于通过 TrollStore 安装的 Henge。",
                    done: jit.method == .trollStore) { path.append(.trollStore) }
                way("使用越狱环境", symbol: "lock.open",
                    detail: JITBootstrap.debuggedAtLaunch ? "Henge 启动时 JIT 已开启。"
                        : JITBootstrap.isJailbroken ? "已检测到越狱环境。请开启“允许应用使用 JIT”。"
                        : "Dopamine 可通过一项设置为所有应用启用 JIT。",
                    done: jit.method == .jailbreak || JITBootstrap.debuggedAtLaunch) { path.append(.jailbreak) }
            }
            if jit.hasPairing && HengeBuiltInJIT.isAvailable {
                Button { path.append(.connect) } label: {
                    Label("使用当前配对继续", systemImage: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.top, 4)
            }
        } actions: {
            Button("暂不开启") { close() }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textDim)
        }
    }

    private func way(_ title: String, symbol: String, detail: String, done: Bool,
                     enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(detail).font(.system(size: 13)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: done ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: done ? 18 : 13, weight: .semibold))
                    .foregroundStyle(done ? .green : Theme.textDim.opacity(0.7))
            }
            .padding(14)
            .contentShape(Rectangle())
            .hengeCard()
        }
        .buttonStyle(CardButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    // MARK: Pair on this device

    private var pairedOnDevice: Bool {
        if case .paired = pairing.phase { return true }
        return false
    }

    private var pairOnDevice: some View {
        page(symbol: "iphone.radiowaves.left.and.right", title: "在此 \(device) 上配对",
             subtitle: "Henge 会在无线局域网中作为一台电脑提供配对服务，"
                     + "让这台 \(device) 按照与 Mac 配对的方式完成连接。") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "开启 Wi-Fi，轻点下方的**开始配对**，并允许访问本地网络。",
                      done: pairing.phase != .idle)
                point(2, "打开**设置 › 隐私与安全性 › 开发者模式**，向下滚动并轻点"
                       + "**与 \(OnDevicePairing.hostName) 配对**。",
                      done: pairing.isShowingPin || pairedOnDevice)
                point(3, "输入 Henge 显示的配对码。配对码也会显示在横幅和通知中，"
                       + "可直接查看。",
                      done: pairedOnDevice)
                point(4, "返回 Henge。", done: pairedOnDevice)
            }
            .padding(16).hengeCard()
            pairingStatus
        } actions: {
            switch pairing.phase {
            case .idle, .failed:
                Button { pairing.start() } label: {
                    Label("开始配对", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .waiting, .pin:
                Button("取消配对", role: .cancel) { pairing.cancel() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textDim)
            case .paired:
                Button("继续") { path.append(.connect) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    @ViewBuilder private var pairingStatus: some View {
        switch pairing.phase {
        case .idle:
            EmptyView()
        case .waiting:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("正在等待这台 \(device)…").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                Button("打开设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.system(size: 14, weight: .semibold))
                if pairing.backgroundLimited {
                    Text("当前安装版本只能在后台等待约 30 秒，"
                       + "请立即前往系统设置完成配对。")
                        .font(.system(size: 13)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).hengeCard()
        case .pin(let pin):
            VStack(spacing: 8) {
                Text("在这台 \(device) 上输入此配对码").font(.system(size: 14))
                    .foregroundStyle(Theme.textDim)
                Text(pin).font(.system(size: 40, weight: .bold, design: .monospaced)).tracking(6)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .accessibilityLabel("配对码 \(pin.map(String.init).joined(separator: " "))")
            }
            .frame(maxWidth: .infinity)
            .padding(18).hengeCard(high: true)
        case .paired(let name):
            outcome("已与 \(name) 配对", ok: true)
        case .failed(let message):
            outcome(message, ok: false)
        }
    }

    // MARK: Import a pairing file

    private var importFile: some View {
        page(symbol: "doc.badge.plus", title: "使用配对文件",
             subtitle: "在电脑上生成的配对文件也能让 Henge 与这台 \(device) 建立连接。") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "在电脑上按照"
                       + "[StikDebug 配对文件指南](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md)为这台 \(device) 生成配对文件。",
                      done: jit.pairingSource == .imported)
                point(2, "将文件保存到“文件”应用，或通过隔空投送发送到这台 \(device)。",
                      done: jit.pairingSource == .imported)
                point(3, "轻点**选择配对文件**并选中该文件。", done: jit.pairingSource == .imported)
            }
            .padding(16).hengeCard()
            Label("配对文件保存在 Henge 的 Documents 文件夹中，仅发送给 Henge 自带的辅助进程。",
                  systemImage: "lock.fill")
                .font(.system(size: 13)).foregroundStyle(Theme.textDim)
            if let error = jit.error { outcome(error, ok: false) }
        } actions: {
            if jit.pairingSource == .imported {
                Button("继续") { path.append(.connect) }.buttonStyle(PrimaryButtonStyle())
                Button("选择其他文件") { importing = true }
                    .font(.system(size: 15, weight: .medium))
            } else {
                Button { importing = true } label: { Label("选择配对文件", systemImage: "folder") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    // MARK: LocalDevVPN

    private var connect: some View {
        page(symbol: "network.badge.shield.half.filled", title: "连接 LocalDevVPN",
             subtitle: "Henge 的辅助进程通过本地 VPN 访问这台 \(device) 的调试服务。"
                     + "所有通信都在这台 \(device) 内完成。") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "从 App Store 安装 [LocalDevVPN](\(LocalDevVPN.appStore.absoluteString))。",
                      done: LocalDevVPN.isInstalled)
                point(2, "轻点**连接 LocalDevVPN**。VPN 开启后会自动返回 Henge。")
                point(3, "每次开启 JIT 时，请保持 VPN 已连接。")
            }
            .padding(16).hengeCard()
        } actions: {
            Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
                .buttonStyle(PrimaryButtonStyle())
            Button("已连接") { path.append(.enable) }
                .font(.system(size: 15, weight: .medium))
        }
    }

    // MARK: Enable

    private var attached: Bool { jit.attachGeneration > 0 || JITBootstrap.debuggedFlag }

    private var enable: some View {
        page(symbol: "bolt.badge.checkmark", title: "开启 JIT",
             subtitle: "首次检查会下载并挂载 Apple 的开发者磁盘映像，"
                     + "可能需要一分钟。") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "轻点**检查配置**。Henge 会检查 LocalDevVPN 并准备开发者磁盘映像。",
                      done: jit.prepared || attached)
                point(2, "轻点**启用 JIT**。辅助进程连接成功后，即可启动 Mac。", done: attached)
            }
            .padding(16).hengeCard()

            if jit.busy {
                HStack(spacing: 11) {
                    ProgressView().tint(Theme.accent)
                    Text(jit.status ?? "正在处理…").font(.system(size: 14)).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                .padding(16).hengeCard(high: true)
            } else if attached {
                outcome("JIT 已开启，可以启动 Mac。", ok: true)
            } else if let error = jit.error {
                VStack(alignment: .leading, spacing: 10) {
                    outcome(error, ok: false)
                    if jit.advice?.actions.contains(.pairAgain) == true {
                        Button(OnDevicePairing.isSupported ? "重新配对" : "导入新的配对文件") {
                            path = [OnDevicePairing.isSupported ? .pairOnDevice : .importFile]
                        }
                        .font(.system(size: 14, weight: .semibold))
                    }
                    if jit.advice?.actions.contains(.connectLocalDevVPN) == true {
                        Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
            } else if let status = jit.status {
                outcome(status, ok: true)
            }

            if !attached {
                Button("重置开发者磁盘映像", role: .destructive) { jit.resetDDI() }
                    .font(.system(size: 13, weight: .medium))
                    .disabled(jit.busy)
                    .padding(.top, 4)
            }
        } actions: {
            if attached {
                Button("完成") { close() }.buttonStyle(PrimaryButtonStyle())
            } else if jit.prepared {
                Button { jit.enableBuiltIn() } label: { Label("启用 JIT", systemImage: "bolt.fill") }
                    .buttonStyle(PrimaryButtonStyle(enabled: !jit.busy))
                    .disabled(jit.busy)
            } else {
                Button("检查配置") { jit.prepareBuiltIn() }
                    .buttonStyle(PrimaryButtonStyle(enabled: !jit.busy))
                    .disabled(jit.busy)
            }
        }
    }

    // MARK: StikDebug

    private var stikDebug: some View {
        page(symbol: "ant", title: "使用 StikDebug",
             subtitle: "StikDebug 是用于连接 Henge 的独立调试应用。Henge 会自动向其发送 JIT 脚本，"
                     + "可直接使用。") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "安装 [StikDebug](https://github.com/StikDebug/StikDebug/releases/latest)。",
                      done: JITBootstrap.isStikDebugInstalled)
                point(2, "将这台 \(device) 的配对文件导入 StikDebug。")
                point(3, "安装并连接 [LocalDevVPN](\(LocalDevVPN.appStore.absoluteString))。")
                point(4, "每次启动 Mac 时，Henge 都会打开 StikDebug，连接成功后自动返回。")
            }
            .padding(16).hengeCard()
        } actions: {
            Button("使用 StikDebug") {
                jit.method = .stikDebug
                HengeLog.log("ui", "JIT method set to StikDebug")
                close()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: TrollStore

    private var trollStore: some View {
        page(symbol: "sparkles", title: "使用 TrollStore",
             subtitle: "TrollStore 可以直接为通过它安装的应用启用 JIT，"
                     + "整个过程可在设备上完成。") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "在 TrollStore 支持的 iOS 版本上，通过 TrollStore 安装 Henge.ipa。该文件包含"
                       + "TrollStore 支持的权限，也可通过侧载工具安装。",
                      done: JITBootstrap.isInstalledWithTrollStore)
                point(2, "在 TrollStore 的设置中开启 URL Scheme，以便它接收启用 JIT 的请求。")
                point(3, "每次启动 Mac 时，Henge 都会请求 TrollStore 启用 JIT。TrollStore 会打开 Henge，"
                       + "短暂连接后断开，从而授予 Henge 执行自身生成代码的权限。")
            }
            .padding(16).hengeCard()
            if !JITBootstrap.isTrollStoreInstalled {
                Label("这台 \(device) 上尚未检测到 TrollStore。它支持 iOS 14.0 至 17.0。", systemImage: "info.circle")
                    .font(.system(size: 13)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("使用 TrollStore") {
                jit.method = .trollStore
                HengeLog.log("ui", "JIT method set to TrollStore")
                close()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Jailbreak

    private var jailbreak: some View {
        page(symbol: "lock.open", title: "使用越狱环境",
             subtitle: "在通过 Dopamine 越狱的设备上，开启对应设置后，越狱环境会在应用启动时将其标记为"
                     + "已调试状态，允许应用执行自身生成的代码。Henge 即可使用 JIT。") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "打开 Dopamine 并进入设置。", done: JITBootstrap.isJailbroken)
                point(2, "开启“允许应用使用 JIT”（Allow JIT in Apps）。")
                point(3, "完全关闭 Henge 后重新打开。此设置会在应用启动时生效。",
                      done: JITBootstrap.debuggedAtLaunch)
            }
            .padding(16).hengeCard()
            if JITBootstrap.debuggedAtLaunch {
                Label("Henge 启动时已被标记为已调试状态，JIT 已开启。", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(.green)
            } else if !JITBootstrap.isJailbroken {
                Label("这台 \(device) 上未检测到越狱环境。", systemImage: "info.circle")
                    .font(.system(size: 13)).foregroundStyle(Theme.textDim)
            }
        } actions: {
            Button("使用越狱环境") {
                jit.method = .jailbreak
                HengeLog.log("ui", "JIT method set to jailbreak")
                close()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Pieces

    private func page<Content: View, Actions: View>(
        symbol: String, title: String, subtitle: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions) -> some View {
        ZStack {
            Theme.backdrop
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 56, height: 56)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text(title).font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.system(size: 15)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    content()
                }
                .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 24)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) { actions() }
                .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 16)
                .background(Theme.backdrop)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("关闭") { close() }
            }
        }
    }

    private func point(_ number: Int, _ text: String, done: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.18) : Theme.accentSoft)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.green)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 26, height: 26)
            Text(.init(text))
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func outcome(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(ok ? .green : .red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).hengeCard()
    }
}
