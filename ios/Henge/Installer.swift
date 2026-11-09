// Simplified Chinese translation, 2026-11-09.
import Foundation
import UIKit

/// A macOS restore image Apple publishes for virtual Macs (VirtualMac2,1).
struct MacOSRelease: Identifiable, Hashable {
    let id: String        // build
    let name: String
    let url: URL
    let bytes: Int64
    let note: String

    /// The builds offered, newest last. Apple's catalog (mesu.apple.com) only lists the newest;
    /// these are the same images from Apple's CDN, and Apple still signs them for virtual Macs.
    static let all: [MacOSRelease] = [
        MacOSRelease(id: "24G90", name: "macOS Sequoia 15.6.1",
                     url: URL(string: "https://updates.cdn-apple.com/2025SummerFCS/fullrestores/093-10809/CFD6DD38-DAF0-40DA-854F-31AAD1294C6F/UniversalMac_15.6.1_24G90_Restore.ipsw")!,
                     bytes: 16_035 << 20, note: "推荐使用，Henge 已在此版本上测试。"),
        MacOSRelease(id: "25G83", name: "macOS Tahoe 26.6.2",
                     url: URL(string: "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-75212/A2A24B94-1FC1-45A3-93F7-C51B02AF1F4D/UniversalMac_26.6.2_25G83_Restore.ipsw")!,
                     bytes: 18_856 << 20, note: "尚未在 Henge 中测试。"),
        MacOSRelease(id: "26B123", name: "macOS 27.2",
                     url: URL(string: "https://updates.cdn-apple.com/2026FallFCS/c9671975-52db-4fb5-9af2-00217169ba8d/UniversalMac_27.2_26B123_Restore.ipsw")!,
                     bytes: 24_409 << 20, note: "最新版本，尚未在 Henge 中测试。"),
    ]
}

/// Downloads a restore image and installs it on a new virtual Mac, on the
/// iPhone: the machine boots its ROM in DFU mode and the restore runs over its
/// USB port, as Virtualization.framework's installer does on a Mac.
@MainActor
final class Installer: NSObject, ObservableObject {
    static let shared = Installer()

    enum Phase: Equatable {
        case idle
        case downloading
        case preparing
        case installing
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    @Published private(set) var step: Int = 0
    @Published private(set) var stepProgress: Double = 0
    @Published private(set) var machineName = ""

    private var session: URLSession?
    /* Background time, so a moment out of the foreground (a notification, iPhone Mirroring reconnecting)
       does not suspend the restore at once; iOS gives about 30 s. */
    private var grace = UIBackgroundTaskIdentifier.invalid
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    nonisolated(unsafe) private var downloadTarget: URL? // set before the task starts, read by the delegate
    private var lastResumeData: Data?

    var busy: Bool {
        switch phase {
        case .downloading, .preparing, .installing: return true
        default: return false
        }
    }

    nonisolated static var imageDirectory: URL { Machines.root.appendingPathComponent("Restore images", isDirectory: true) }
    nonisolated static func imagePath(_ r: MacOSRelease) -> URL { imageDirectory.appendingPathComponent("\(r.id).ipsw") }

    /// The size of the image on this iPhone, if a whole one is there (the listed sizes are rounded).
    static func imageSize(_ r: MacOSRelease) -> Int64? {
        let values = try? imagePath(r).resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize, Int64(size) > r.bytes / 2 else { return nil }
        return Int64(size)
    }

    static func haveImage(_ r: MacOSRelease) -> Bool { imageSize(r) != nil }

    static func deleteImage(_ r: MacOSRelease) { try? FileManager.default.removeItem(at: imagePath(r)) }

    /// Free space an install takes: the new Mac's disk, and the download if it is not here yet.
    static func spaceNeeded(_ r: MacOSRelease) -> Int64 { (haveImage(r) ? 0 : r.bytes) + newMacBytes }
    private static let newMacBytes: Int64 = 24 << 30

    func reset() { if !busy { phase = .idle } }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    func start(_ release: MacOSRelease, name: String, ramMB: Int, cpus: Int, keepImage: Bool) {
        guard !busy else { return }
        machineName = name
        UIApplication.shared.isIdleTimerDisabled = true // the screen locking would suspend the download and the restore
        grace = UIApplication.shared.beginBackgroundTask(withName: "Henge install") {
            MainActor.assumeIsolated { Installer.shared.endGrace() }
        }
        Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false; endGrace() }
            var made: VirtualMac?
            do {
                try checkSpace(release)
                let rom = try await BootROM.file() // before the long download, so a problem shows up at once
                HengeLog.log("install", "boot ROM ready")
                let ipsw = try await download(release)
                phase = .preparing
                var mac = try prepare(name: name, ramMB: ramMB, rom: rom)
                mac.osName = release.name
                made = mac
                phase = .installing
                try await install(mac, ipsw: ipsw, cpus: cpus)
                if !keepImage { try? FileManager.default.removeItem(at: ipsw) }
                HengeLog.log("install", "\(name): installed \(release.name)")
                phase = .done("\(release.name) 已安装到 \(name)。请在后台上划关闭 Henge，重新打开后轻点“启动”。")
            } catch {
                HengeLog.log("install", "failed: \(error.localizedDescription)")
                // A half-installed Mac is no use, and its disk can be many gigabytes. The download stays.
                if let made, henge_vm_state() != 1 { try? FileManager.default.removeItem(at: made.directory) }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func checkSpace(_ r: MacOSRelease) throws {
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let needed = Self.spaceNeeded(r)
        if free > 0 && free < needed {
            throw message("本次安装需要约 \(ByteText.string(UInt64(needed))) 可用空间，此 \(Device.name) 当前可用 \(ByteText.string(UInt64(free)))。")
        }
    }

    // MARK: Download

    private func download(_ r: MacOSRelease) async throws -> URL {
        let dest = Self.imagePath(r)
        try FileManager.default.createDirectory(at: Self.imageDirectory, withIntermediateDirectories: true)
        Machines.excludeFromBackup(Self.imageDirectory)
        if Self.haveImage(r) {
            HengeLog.log("install", "using the downloaded \(r.name)")
            return dest
        }
        phase = .downloading
        received = 0
        expected = r.bytes
        downloadTarget = dest
        HengeLog.log("install", "downloading \(r.url.absoluteString)")
        for attempt in 1...20 {
            do {
                return try await downloadOnce(r.url)
            } catch let error as URLError where error.code != .cancelled && attempt < 20 {
                lastResumeData = error.downloadTaskResumeData ?? lastResumeData
                HengeLog.log("install", "download interrupted (\(error.localizedDescription)); resuming")
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        throw message("下载多次失败，请检查网络连接后重试。")
    }

    private func downloadOnce(_ url: URL) async throws -> URL {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 48 * 3600
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            downloadContinuation = c
            let task = lastResumeData.map { s.downloadTask(withResumeData: $0) } ?? s.downloadTask(with: url)
            lastResumeData = nil
            task.resume()
        }
    }

    // MARK: The new machine

    private func prepare(name: String, ramMB: Int, rom: URL) throws -> VirtualMac {
        // A new machine identity, as VZMacMachineIdentifier makes one: a random ECID.
        let ecid = UInt64.random(in: 1 << 40 ..< 1 << 62)
        var mac = VirtualMac(name: name, ecid: ecid, seed: 0, ramMB: ramMB, diskBytes: 64 << 30)
        (mac.screenWidth, mac.screenHeight) = Device.fittingScreen
        let fm = FileManager.default
        try fm.createDirectory(at: mac.directory, withIntermediateDirectories: true)
        Machines.excludeFromBackup(Machines.root)
        try? fm.removeItem(at: mac.rom)
        try fm.copyItem(at: rom, to: mac.rom)
        guard fm.createFile(atPath: mac.disk.path, contents: nil) else { throw message("无法创建磁盘。") }
        let h = try FileHandle(forWritingTo: mac.disk)
        try h.truncate(atOffset: UInt64(64) << 30) // sparse: blocks are only used as macOS writes them
        try h.close()
        guard henge_make_aux(mac.aux.path) == 0 else { throw message("无法创建辅助存储。") }
        let info: [String: Any] = ["name": name, "ecid": ecid, "seed": 0, "ramMB": ramMB]
        try JSONSerialization.data(withJSONObject: info).write(to: mac.directory.appendingPathComponent("machine.json"))
        mac.diskBytes = 64 << 30
        HengeLog.log("install", "new machine \(name): ECID \(ecid), 64 GB disk")
        return mac
    }

    // MARK: The restore

    private func install(_ mac: VirtualMac, ipsw: URL, cpus: Int) async throws {
        guard JITBootstrap.ready else { throw message("请先启用 JIT，安装程序运行 Mac 恢复系统时需要使用 JIT。") }
        // The restore needs 2 GB, whatever the Mac is set to use afterwards, and gets at most 4 GB: the restore system
        // caches the ~15 GB it writes, so it fills all the memory it is given, and 10 GB of a 12 GB iPhone's RAM in use
        // (it is outside Henge's footprint, so iOS does not stop it) stalls the whole phone two thirds of the way through.
        var restoring = mac
        restoring.ramMB = min(max(mac.ramMB, 2048), 4096)
        let ram = GuestMemory.prepare(restoring)
        guard ram >= 2048 else { throw message("安装还需要几 GB 可用存储空间，用于 Mac 的内存。") }
        setenv("HV_WRITE_CACHE", "0", 1) // the ~15 GB the restore writes goes straight to storage (host/disk.c); this process runs no other Mac
        let work = mac.directory.appendingPathComponent("restore", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var buffer = [CChar](repeating: 0, count: 256)
        let rc = henge_vm_install(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, ipsw.path, work.path, ram, Int32(cpus),
                                  &buffer, buffer.count)
        if rc != 0 { throw message(String(cString: buffer)) }
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            step = Int(henge_install_step())
            stepProgress = henge_install_progress()
            if step == 100 { break }
            if step == 101 { throw message("恢复失败。请在“设置”中查看日志，或打开 Documents/henge.log 了解原因。") }
            if henge_vm_state() == 2 && step < 100 {
                // The restore ends with the machine restarting, and idevicerestore finishes a
                // little after; a stop with no result after that is a failure.
                for _ in 0..<90 where henge_install_step() < 100 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                if henge_install_step() == 100 { break }
                throw message("恢复过程中虚拟机已停止（\(String(cString: henge_vm_exit_reason()))）。")
            }
        }
        // In the list before anything else: stopping the restore system can take a while, and if Henge is
        // stopped meanwhile (the phone locked) a finished Mac must not be left on the disk unlisted.
        try? (mac.osName ?? "").write(to: mac.directory.appendingPathComponent(Machines.installedMarker), atomically: true, encoding: .utf8)
        Machines.shared.add(mac)
        HengeLog.log("install", "\(mac.name): restore finished, added to the Macs")
        if henge_vm_state() == 1 { henge_vm_stop() }
        try? FileManager.default.removeItem(at: work)
    }

    static func stepName(_ step: Int) -> String {
        switch step {
        case 0: return "正在查找 Mac"
        case 1: return "正在启动安装程序"
        case 2: return "正在写入 macOS"
        case 3: return "正在校验 macOS"
        case 4: return "正在安装固件"
        case 6, 7: return "正在安装系统文件"
        default: return "正在安装"
        }
    }

    private func message(_ text: String) -> NSError {
        NSError(domain: "Henge", code: 2, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

extension Installer: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            self.received = totalBytesWritten
            if totalBytesExpectedToWrite > 0 { self.expected = totalBytesExpectedToWrite }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64,
                                expectedTotalBytes: Int64) {
        Task { @MainActor in self.received = fileOffset }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file is gone when this returns: move it now, on this thread.
        let target = self.downloadTarget
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            guard let target, status == 200 || status == 206 else {
                throw NSError(domain: "Henge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Apple 服务器返回状态码 \(status)。"])
            }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            Task { @MainActor in
                self.downloadContinuation?.resume(returning: target)
                self.downloadContinuation = nil
            }
        } catch {
            Task { @MainActor in
                self.downloadContinuation?.resume(throwing: error)
                self.downloadContinuation = nil
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.downloadContinuation?.resume(throwing: error)
            self.downloadContinuation = nil
        }
    }
}
