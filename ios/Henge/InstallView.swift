// Simplified Chinese translation, 2026-11-09.
// Separate mobile-data downloads from JIT-dependent installation, 2026-11-09.
import SwiftUI

/// Download macOS (or use a copy already on this device) and install it on a new Mac.
struct InstallView: View {
    @ObservedObject private var installer = Installer.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @State private var jitReady = JITBootstrap.ready
    @StateObject private var display = DisplayRouter()
    @State private var release = MacOSRelease.all.first(where: Installer.haveImage) ?? MacOSRelease.all[0]
    @State private var name = "Mac"
    @State private var ramGB = Device.suggestedRAMGB
    @State private var deleteAfter = false
    @State private var refresh = 0 // redraws the list when a download is deleted
    @State private var details = false
    @State private var stageStarted = Date()
    @State private var stageSeen = -1
    @State private var confirmDeleteDownload: MacOSRelease?
    @AppStorage("henge.cpus") private var cpus = 4

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    switch installer.phase {
                    case .idle: chooser
                    case .downloading, .preparing, .installing: progress
                    case .downloaded(let text): finished(text, downloaded: true)
                    case .done(let text): finished(text)
                    case .failed(let text): failed(text)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .deskColumn()
            }
            .background(Desk.page)
            .navigationTitle(installer.busy ? (installer.downloadingOnly ? "正在下载" : "正在安装") : "安装 macOS")
            .task {
                while !Task.isCancelled { // the region may be claimed after a hand-off to StikDebug
                    jitReady = JITBootstrap.ready
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    // MARK: Choosing

    @ViewBuilder private var chooser: some View {
        DeskHeading("版本")
        VStack(spacing: 0) {
            ForEach(MacOSRelease.all) { r in
                HStack(spacing: 0) {
                    Button { release = r } label: { versionRow(r) }
                        .buttonStyle(.plain)
                    if Installer.haveImage(r) && !installer.busy { // restore images are 15-25 GB: deleting one should be easy to find
                        Button { confirmDeleteDownload = r } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Desk.dim)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除已下载的 \(r.name)")
                        .padding(.trailing, 6)
                    }
                }
                    .contextMenu {
                        if Installer.haveImage(r) {
                            Button("删除下载文件", role: .destructive) { confirmDeleteDownload = r }
                        }
                    }
                if r.id != MacOSRelease.all.last?.id { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
            }
        }
        .deskCard()
        .id(refresh)
        .confirmationDialog("删除此下载文件？", isPresented: Binding(get: { confirmDeleteDownload != nil }, set: { if !$0 { confirmDeleteDownload = nil } }),
                            titleVisibility: .visible) {
            Button("删除下载文件", role: .destructive) {
                if let r = confirmDeleteDownload { Installer.deleteImage(r) }
                refresh += 1
            }
        }

        DeskHeading("新建 Mac")
        VStack(spacing: 0) {
            TextField("名称", text: $name)
                .font(.system(size: 16))
                .padding(.horizontal, 17)
                .padding(.vertical, 14)
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            Stepper(value: $ramGB, in: Device.memoryChoices) {
                HStack {
                    Text("内存").font(.system(size: 16))
                    Spacer()
                    Text("\(ramGB) GB").font(.system(size: 16, weight: .semibold))
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            if let note = Device.memoryNote(ramGB) {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Desk.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 17)
                    .padding(.bottom, 10)
            }
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            Toggle("安装后删除下载文件", isOn: $deleteAfter)
                .font(.system(size: 16))
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
        }
        .deskCard()

        if Installer.haveImage(release) {
            Button("安装") {
                installer.start(release, name: name.isEmpty ? "Mac" : name, ramMB: ramGB * 1024, cpus: cpus, keepImage: !deleteAfter)
            }
            .buttonStyle(DeskButtonStyle(enabled: jitReady && !Device.chipTooOld))
            .disabled(!jitReady || Device.chipTooOld)
            .padding(.top, 20)
            Text(Device.chipTooOld ? Device.chipTooOldText : jitReady ? "请保持 Henge 打开，并为 \(Device.name) 接通电源。约需 \(ByteText.string(UInt64(Installer.spaceNeeded(release)))) 可用空间。"
                                    : JITBootstrap.lastFailure ?? "镜像已下载，请开启 JIT 后安装。\(jit.automaticDescription)")
                .font(.system(size: 13))
                .foregroundStyle(Desk.dim)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
        } else {
            Button("下载镜像") {
                installer.start(release, name: name.isEmpty ? "Mac" : name, ramMB: ramGB * 1024, cpus: cpus,
                                keepImage: true, downloadOnly: true)
            }
            .buttonStyle(DeskButtonStyle())
            .padding(.top, 20)
            Text("支持 Wi-Fi 和移动数据，约需 \(ByteText.string(UInt64(release.bytes))) 可用空间。下载完成后，开启 JIT 即可安装。")
                .font(.system(size: 13))
                .foregroundStyle(Desk.dim)
                .multilineTextAlignment(.center)
                .padding(.top, 10)
            if Device.chipTooOld {
                Text(Device.chipTooOldText)
                    .font(.system(size: 13))
                    .foregroundStyle(Desk.dim)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
            }
        }
        if !jitReady && !Device.chipTooOld {
            // Before any Mac exists, this is the only place to ask for JIT (#23).
            Button("开启 JIT") { jit.enable() }
                .buttonStyle(DeskButtonStyle())
                .padding(.top, 12)
        }
    }

    private func versionRow(_ r: MacOSRelease) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.system(size: 16, weight: .medium)).foregroundStyle(Desk.text)
                if let size = Installer.imageSize(r) {
                    Text("已下载，\(ByteText.string(UInt64(size)))").font(.system(size: 13)).foregroundStyle(Desk.good)
                } else {
                    Text("下载大小为 \(ByteText.string(UInt64(r.bytes)))").font(.system(size: 13)).foregroundStyle(Desk.dim)
                }
                Text(r.note).font(.system(size: 13)).foregroundStyle(Desk.dim)
            }
            Spacer()
            if release == r { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Desk.accentLight) }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: Going

    private static let stages = ["下载", "启动安装程序", "写入 macOS", "检查 macOS", "完成"]

    private var stage: Int {
        switch installer.phase {
        case .downloading: return 0
        case .preparing: return 1
        default:
            switch installer.step {
            case 0, 1: return 1
            case 2: return 2
            case 3: return 3
            default: return 4
            }
        }
    }

    private var fraction: Double {
        if case .downloading = installer.phase {
            return installer.expected > 0 ? Double(installer.received) / Double(installer.expected) : 0
        }
        return installer.stepProgress
    }

    /// From how this step has gone so far; nothing until there is enough to go on.
    private var timeLeft: String? {
        let elapsed = Date().timeIntervalSince(stageStarted)
        guard stageSeen == stage, fraction > 0.03, fraction < 1, elapsed > 10 else { return nil }
        let minutes = Int((elapsed / fraction * (1 - fraction) / 60).rounded(.up))
        return minutes <= 1 ? "此步骤约剩 1 分钟" : "此步骤约剩 \(minutes) 分钟"
    }

    @ViewBuilder private var progress: some View {
        Text(installer.downloadingOnly
             ? "正在下载 \(installer.machineName)。请保持 Henge 打开。"
             : "正在这台 \(Device.name) 上安装 \(release.name)。请保持 Henge 打开。")
            .font(.system(size: 16))
            .foregroundStyle(Desk.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 16)

        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 0) {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 66, weight: .bold))
                    .monospacedDigit()
                Text(timeLeft ?? (installer.downloadingOnly
                     ? "已下载 \(ByteText.string(UInt64(max(installer.received, 0)))) / \(ByteText.string(UInt64(max(installer.expected, 0))))"
                     : "第 \(stage + 1) 步，共 \(Self.stages.count) 步"))
                    .font(.system(size: 15))
                    .foregroundStyle(Desk.dim)
                    .padding(.top, 2)
                    .padding(.bottom, 16)
                DeskBar(fraction: fraction, height: 11)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .deskCard(radius: 30)
        }
        .onChange(of: stage) { value in
            stageSeen = value
            stageStarted = Date()
        }
        .onAppear {
            stageSeen = stage
            stageStarted = Date()
        }

        if !installer.downloadingOnly {
            DeskHeading("安装步骤")
            VStack(spacing: 0) {
                ForEach(Array(Self.stages.enumerated()), id: \.offset) { i, title in
                    HStack {
                        Text(title)
                            .font(.system(size: 16, weight: i == stage ? .semibold : .regular))
                            .foregroundStyle(i > stage ? Desk.faint : Desk.text)
                        Spacer()
                        if i < stage {
                            Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Desk.good)
                        } else if i == stage {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 17)
                    .padding(.vertical, 13)
                    if i < Self.stages.count - 1 { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
                }
            }
            .deskCard()
        }

        Button(details ? "隐藏详情" : "显示详情") { withAnimation { details.toggle() } }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Desk.accentLight)
            .padding(.top, 14)
        if details {
            VStack(spacing: 12) {
                if case .installing = installer.phase {
                    BootDisplay(display: display, role: .device)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                LogTail()
            }
            .padding(14)
            .deskCard()
            .padding(.top, 10)
        }
    }

    private func finished(_ text: String, downloaded: Bool = false) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Desk.good).padding(.top, 8)
            Text(downloaded ? "下载完成" : "安装完成").font(.system(size: 24, weight: .bold))
            Text(text).font(.system(size: 15)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
            if downloaded {
                Button("返回安装") { installer.reset() }.buttonStyle(DeskButtonStyle())
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .deskCard(radius: 30)
        .padding(.top, 8)
    }

    @ViewBuilder private func failed(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(installer.downloadingOnly ? "下载失败" : "安装失败").font(.system(size: 22, weight: .bold))
            Text(text).font(.system(size: 15))
            Text(installer.downloadingOnly
                 ? "请检查网络连接、蜂窝数据权限和可用空间，返回后重试。"
                 : "请在多任务界面上滑退出 Henge，然后重新打开再试。每次启动 Henge 只能启动一台 Mac。")
                .font(.system(size: 13)).foregroundStyle(Desk.dim)
            Button("返回") { installer.reset() }.buttonStyle(DeskButtonStyle()).padding(.top, 6)
        }
        .padding(18)
        .deskCard(radius: 30)
        .padding(.top, 8)
        DeskHeading("日志")
        LogTail().padding(14).frame(maxWidth: .infinity, alignment: .leading).deskCard()
    }
}

/// The last lines of Henge's log.
private struct LogTail: View {
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            while !Task.isCancelled {
                lines = Array(HengeLog.recentLines(14))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
