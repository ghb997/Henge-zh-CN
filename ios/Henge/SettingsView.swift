// Simplified Chinese translation, 2026-11-09.
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var jit = JITCoordinator.shared
    @AppStorage(JITCoordinator.autoEnableKey) private var jitAtLaunch = false
    @AppStorage(HardwareMouse.speedKey) private var mouseSpeed = 1.0
    @AppStorage(HardwareMouse.reverseKey) private var reverseScrolling = false
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3
    @AppStorage(EngineTuning.refreshKey) private var refreshRate = 60
    @AppStorage(EngineTuning.fastFlushKey) private var fastFlush = true
    @AppStorage(EngineTuning.wfiSpinKey) private var wfiSpin = false
    @AppStorage(EngineTuning.superblocksKey) private var superblocks = false
    @AppStorage(JITBootstrap.codeCacheKey) private var codeCacheMB = JITBootstrap.defaultCodeCacheMB

    var body: some View {
        NavigationStack {
            Form {
                Section("JIT") {
                    LabeledContent("状态", value: JITBootstrap.ready ? "已开启" : "已关闭")
                    Picker("方式", selection: $jit.method) {
                        ForEach(JITMethod.allCases) { Text($0.title).tag($0) }
                    }
                    Text(jit.method == .automatic ? jit.automaticDescription : "Henge 使用\(jit.method.title)。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("设置 JIT") { jit.showSetup = true }
                    Toggle("打开 Henge 时自动开启 JIT", isOn: $jitAtLaunch)
                    if jitAtLaunch {
                        Text("如果 LocalDevVPN 尚未连接，Henge 会先连接它，然后返回。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("代码区域", value: "\(JITBootstrap.jitBytes >> 20) MB，每次启动时申请一次")
                }
                .listRowBackground(Desk.card)
                Section("内存") {
                    LabeledContent("额外内存", value: Entitlements.increasedMemory ? "已开启" : "已关闭")
                    LabeledContent("Henge 内存上限", value: ByteText.string(UInt64(Entitlements.memoryLimitAtLaunch)))
                    LabeledContent("Henge 可用内存", value: ByteText.string(UInt64(henge_available_memory())))
                    Text(Entitlements.increasedMemory
                         ? "开启 JIT 后，Mac 的内存可独立于此上限分配。如果 iOS 拒绝分配，则使用可用存储空间。"
                         : "当前安装包的签名未包含提高内存上限的权限。请使用包含该权限的证书重新安装 Henge。如果重新安装会覆盖应用数据，请先导出你的 Mac。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                if Device.isPad {
                    Section("鼠标与触控板") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("指针速度")
                            Slider(value: $mouseSpeed, in: 0.5...3)
                        }
                        Toggle("反向滚动", isOn: $reverseScrolling)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("滚动速度")
                            Slider(value: $scrollSpeed, in: 0.1...1.5)
                        }
                        Text("妙控键盘或蓝牙鼠标可控制 Mac 的指针。指针速度更改会在下次启动 Mac 时生效，滚动速度更改会立即生效。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                Section("性能") {
                    Picker("Mac 刷新率", selection: $refreshRate) {
                        Text("30 Hz").tag(30)
                        Text("60 Hz").tag(60)
                        Text("120 Hz").tag(120)
                    }
                    .pickerStyle(.segmented)
                    Toggle("加快磁盘写入", isOn: $fastFlush)
                    Toggle("加快空闲唤醒", isOn: $wfiSpin)
                    Toggle("超级块（实验性）", isOn: $superblocks)
                    Picker("代码缓存", selection: $codeCacheMB) {
                        Text("1 GB").tag(1024)
                        Text("1.5 GB").tag(1536)
                    }
                    Text("更大的代码缓存可减少清空次数，但会占用更多内存。空间充足时，Henge 会选择 1.5 GB。更改会在下次打开 Henge 时生效。如果无法开启 JIT，请选择 1 GB。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("macOS 每次刷新都会绘制一帧。30 Hz 可为应用留出更多模拟 CPU 资源，但动画较不流畅，60 Hz 则更流畅。加快磁盘写入会按顺序提交写入而不等待完整同步，突然断电可能导致最近写入的数据丢失。加快空闲唤醒会让空闲 CPU 持续等待任务 50 微秒，因此会增加耗电。超级块允许翻译后的代码跨越条件分支继续执行。更改会在下次启动 Mac 时生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("日志") {
                    ShareLink(item: HengeLog.logFileURL) { Label("分享 henge.log", systemImage: "square.and.arrow.up") }
                }
                .listRowBackground(Desk.card)
            }
            .scrollContentBackground(.hidden)
            .background(Desk.page)
            .navigationTitle("设置")
        }
    }
}
