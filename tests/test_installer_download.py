#!/usr/bin/env python3
"""Run Installer.swift's download control flow on macOS against a local server.

UIKit is replaced only in a temporary test copy. The real downloader, lifecycle,
cache paths and phase transitions run with small fixtures and VM/JIT stubs.
"""

import collections
import http.server
import os
from pathlib import Path
import subprocess
import tempfile
import threading


STUBS_AND_TESTS = r'''
import Foundation
import Combine
import Darwin

struct UIBackgroundTaskIdentifier: Equatable {
    let rawValue: Int
    static let invalid = UIBackgroundTaskIdentifier(rawValue: -1)
}

@MainActor final class UIApplication {
    static let shared = UIApplication()
    var isIdleTimerDisabled = false
    var backgroundTasks = 0
    func beginBackgroundTask(withName: String?, expirationHandler: (() -> Void)?) -> UIBackgroundTaskIdentifier {
        backgroundTasks += 1
        return UIBackgroundTaskIdentifier(rawValue: backgroundTasks)
    }
    func endBackgroundTask(_ task: UIBackgroundTaskIdentifier) {
        backgroundTasks -= 1
    }
}

@MainActor enum JITBootstrap {
    static var ready = false
}

@MainActor enum BootROM {
    static var calls = 0
    static func file() async throws -> URL {
        calls += 1
        throw NSError(domain: "UnexpectedBootROM", code: 1)
    }
}

enum ByteText {
    static func string(_ bytes: UInt64) -> String { "\(bytes) bytes" }
}

enum Device {
    static let name = "test device"
    static let fittingScreen = (1920, 1080)
}

struct VirtualMac {
    var name: String
    var ecid: UInt64
    var seed: UInt64
    var ramMB: Int
    var diskBytes: Int64
    var osName: String?
    var screenWidth: Int?
    var screenHeight: Int?
    var directory: URL { Machines.root.appendingPathComponent("unexpected-machine") }
    var rom: URL { directory.appendingPathComponent("rom.bin") }
    var disk: URL { directory.appendingPathComponent("disk.img") }
    var aux: URL { directory.appendingPathComponent("aux.bin") }
}

@MainActor final class Machines {
    static let shared = Machines()
    nonisolated static let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["INSTALLER_TEST_ROOT"]!)
    nonisolated static let installedMarker = "installed"
    var added = 0
    static func excludeFromBackup(_ url: URL) {}
    func add(_ mac: VirtualMac) { added += 1 }
}

@MainActor enum GuestMemory {
    static var calls = 0
    static func prepare(_ mac: VirtualMac) -> UInt64 {
        calls += 1
        return 4096
    }
}

enum HengeLog {
    static func log(_ category: String, _ message: String) {}
}

@MainActor enum VMCalls {
    static var count = 0
}

@MainActor func henge_vm_state() -> Int32 { 0 }
@MainActor func henge_make_aux(_ path: String) -> Int32 { VMCalls.count += 1; return -1 }
@MainActor func henge_vm_install(_ rom: String, _ disk: String, _ aux: String,
                                 _ ecid: UInt64, _ ipsw: String, _ work: String,
                                 _ ram: UInt64, _ cpus: Int32,
                                 _ buffer: UnsafeMutablePointer<CChar>, _ count: Int) -> Int32 {
    VMCalls.count += 1
    return -1
}
@MainActor func henge_install_step() -> Int32 { 101 }
@MainActor func henge_install_progress() -> Double { 0 }
@MainActor func henge_vm_stop() { VMCalls.count += 1 }
@MainActor func henge_vm_exit_reason() -> UnsafePointer<CChar> {
    UnsafePointer(strdup("unexpected VM call")!)
}

@main struct InstallerDownloadTests {
    @MainActor static func waitUntilFinished(_ installer: Installer) async throws {
        let deadline = Date().addingTimeInterval(15)
        while installer.busy && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(!installer.busy, "download did not finish")
        precondition(!UIApplication.shared.isIdleTimerDisabled, "idle timer was not restored")
        precondition(UIApplication.shared.backgroundTasks == 0, "background task leaked")
    }

    @MainActor static func expectDownloaded(_ installer: Installer) {
        guard case .downloaded = installer.phase else {
            preconditionFailure("expected downloaded, got \(installer.phase)")
        }
        precondition(BootROM.calls == 0, "download requested the boot ROM")
        precondition(GuestMemory.calls == 0 && VMCalls.count == 0, "download started the VM")
        precondition(Machines.shared.added == 0, "download created a Mac")
        precondition(!FileManager.default.fileExists(atPath: Machines.root.appendingPathComponent("unexpected-machine").path))
    }

    @MainActor static func main() async throws {
        let base = ProcessInfo.processInfo.environment["INSTALLER_TEST_URL"]!
        let first = MacOSRelease(id: "first", name: "First release", url: URL(string: base + "/first")!, bytes: 4096, note: "test")
        let second = MacOSRelease(id: "second", name: "Second release", url: URL(string: base + "/second")!, bytes: 8192, note: "test")
        let retry = MacOSRelease(id: "retry", name: "Retry release", url: URL(string: base + "/retry")!, bytes: 4096, note: "test")
        let installer = Installer.shared

        // A download can begin without JIT, and its synchronous busy state blocks a second tap.
        precondition(!JITBootstrap.ready)
        precondition(Installer.spaceNeeded(first, downloadOnly: true) == first.bytes)
        precondition(Installer.spaceNeeded(first) == first.bytes + (24 << 30))
        installer.start(first, name: "First Mac", ramMB: 4096, cpus: 4, keepImage: false, downloadOnly: true)
        precondition(installer.busy, "busy must be set before start returns")
        installer.start(second, name: "Second Mac", ramMB: 4096, cpus: 4, keepImage: false, downloadOnly: true)
        try await waitUntilFinished(installer)
        expectDownloaded(installer)
        precondition(Installer.haveImage(first), "download-only must retain the image even with keepImage=false")
        precondition(Installer.spaceNeeded(first, downloadOnly: true) == 0)
        precondition(Installer.spaceNeeded(first) == (24 << 30))
        precondition(!Installer.haveImage(second), "second tap started another download")
        let firstData = try Data(contentsOf: Installer.imagePath(first))
        precondition(firstData == Data(repeating: 65, count: 4096))

        // Cached download-only requests complete without another HTTP request.
        installer.reset()
        installer.start(first, name: "Cached Mac", ramMB: 4096, cpus: 4, keepImage: false, downloadOnly: true)
        try await waitUntilFinished(installer)
        expectDownloaded(installer)

        // Installing a cached image still requires JIT before touching ROM or VM state.
        installer.reset()
        installer.start(first, name: "Install Mac", ramMB: 4096, cpus: 4, keepImage: false)
        try await waitUntilFinished(installer)
        guard case .failed(let message) = installer.phase else {
            preconditionFailure("installation without JIT should fail")
        }
        precondition(message.contains("JIT"), "missing JIT should explain the installation requirement")
        precondition(BootROM.calls == 0 && VMCalls.count == 0 && GuestMemory.calls == 0)
        precondition(Installer.haveImage(first), "failed installation removed its cached image")

        // A new release gets its own data and progress rather than the previous request's state.
        installer.reset()
        installer.start(second, name: "Second Mac", ramMB: 4096, cpus: 4, keepImage: true, downloadOnly: true)
        try await waitUntilFinished(installer)
        expectDownloaded(installer)
        let secondData = try Data(contentsOf: Installer.imagePath(second))
        let firstDataAfterSecond = try Data(contentsOf: Installer.imagePath(first))
        precondition(secondData == Data(repeating: 66, count: 8192))
        precondition(firstDataAfterSecond == firstData)
        precondition(installer.received == 8192 && installer.expected == 8192)

        // An HTTP error is retryable by the user in the same app process.
        installer.reset()
        installer.start(retry, name: "Retry Mac", ramMB: 4096, cpus: 4, keepImage: true, downloadOnly: true)
        try await waitUntilFinished(installer)
        guard case .failed = installer.phase else { preconditionFailure("HTTP error should fail") }
        precondition(!Installer.haveImage(retry), "HTTP error body was cached as a restore image")
        installer.reset()
        installer.start(retry, name: "Retry Mac", ramMB: 4096, cpus: 4, keepImage: true, downloadOnly: true)
        try await waitUntilFinished(installer)
        expectDownloaded(installer)
        let retriedData = try Data(contentsOf: Installer.imagePath(retry))
        precondition(retriedData == Data(repeating: 67, count: 4096))
        print("Installer download: all checks passed")
    }
}
'''


def main():
    root = Path(__file__).resolve().parents[1]
    source = (root / "ios/Henge/Installer.swift").read_text(encoding="utf-8")
    configuration = source.split("private func downloadOnce", 1)[1].split("let s = URLSession", 1)[0]
    for property_name in ("allowsCellularAccess", "allowsExpensiveNetworkAccess", "allowsConstrainedNetworkAccess"):
        assert f"cfg.{property_name} = true" in configuration, property_name
    view = (root / "ios/Henge/InstallView.swift").read_text(encoding="utf-8")
    download_button = view.split('Button("下载镜像")', 1)[1].split('Text("支持 Wi-Fi', 1)[0]
    assert "downloadOnly: true" in download_button
    assert ".disabled" not in download_button and "jitReady" not in download_button
    assert ".buttonStyle(DeskButtonStyle())" in download_button
    assert source.count("import UIKit") == 1
    source = source.replace("import UIKit", "import Combine")
    requests = collections.Counter()
    payloads = {"/first": b"A" * 4096, "/second": b"B" * 8192, "/retry": b"C" * 4096}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests[self.path] += 1
            if self.path == "/retry" and requests[self.path] == 1:
                self.send_response(503)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            payload = payloads.get(self.path)
            if payload is None:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Content-Type", "application/octet-stream")
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, format, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="henge-installer-test-") as temporary:
            directory = Path(temporary)
            installer = directory / "Installer.swift"
            harness = directory / "InstallerDownloadTests.swift"
            executable = directory / "test-installer-download"
            installer.write_text(source, encoding="utf-8")
            harness.write_text(STUBS_AND_TESTS, encoding="utf-8")
            subprocess.run(["xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "5", "-parse-as-library",
                            str(installer), str(harness), "-o", str(executable)], check=True)
            environment = dict(os.environ)
            environment["INSTALLER_TEST_ROOT"] = str(directory / "cache")
            environment["INSTALLER_TEST_URL"] = f"http://127.0.0.1:{server.server_port}"
            subprocess.run([str(executable)], env=environment, check=True, timeout=90)
        assert requests == {"/first": 1, "/second": 1, "/retry": 2}, requests
        print("Installer HTTP requests and cache reuse: all checks passed")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == "__main__":
    main()
