// Simplified Chinese translation, 2026-11-09.
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import StikJIT

/// The debugger half of Built-in StikJIT (docs/06-built-in-jit.md).
///
/// A process cannot synchronously debug itself, so Henge starts this extension,
/// sends it its PID, the pairing file and henge-jit.js, and StikJIT attaches over
/// LocalDevVPN and services the script's trap requests until Henge detaches.
private enum HengeJITWork {
    /// One request at a time: enabling JIT holds this queue while the debugger is attached.
    static let queue = DispatchQueue(label: "com.henge.app.jit-helper")

    static func handle(_ request: HengeJITRequest) -> HengeJITRequest.Response {
        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StikJIT", isDirectory: true)
        let paths = DDIPaths.default(in: root)
        var configuration = StikJIT.Configuration.default
        /// Appended to the reply so Henge's log shows how the port was chosen.
        var portNote = ""
        if let rsdPort = request.rsdPort {
            configuration.rsdPort = rsdPort
        } else if request.operation != .resetDDI {
            // Henge found no advertised port. StikJIT's 49152 is closed when the device picked another at boot.
            let lookup = RSDPortResolver.resolve()
            NSLog("[HengeJIT] RemotePairing port: %@", lookup.detail)
            if let port = lookup.port { configuration.rsdPort = port }
            portNote = "［辅助进程端口查询结果为 \(lookup.detail)，使用端口 \(configuration.rsdPort)］"
        }

        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            if request.operation == .resetDDI {
                try StikJIT.resetCachedDDI(at: paths)
                return .init(success: true, message: "开发者磁盘映像缓存已重置。",
                             txmPresent: StikJIT.isTXMPresent)
            }

            guard let pairingData = request.pairingData, !pairingData.isEmpty else {
                throw NSError(domain: "HengeJITHelper", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "未提供配对文件。"])
            }
            let pairingURL = root.appendingPathComponent("pairingFile-\(UUID().uuidString).plist")
            try pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }

            switch request.operation {
            case .prepare:
                let readiness = StikJIT.prepareDevice(
                    pairingFile: pairingURL, paths: paths, configuration: configuration,
                    progress: { NSLog("[HengeJIT] prepare: %@", String(describing: $0)) })
                switch readiness {
                case .ready(let security):
                    return .init(success: true,
                                 message: "LocalDevVPN 连接正常，开发者磁盘映像已就绪。" + portNote,
                                 txmPresent: security.isTXMPresent)
                case .unreachable(let reason), .preparationFailed(let reason):
                    return .init(success: false, message: reason + portNote, txmPresent: StikJIT.isTXMPresent)
                @unknown default:
                    return .init(success: false, message: "StikJIT 返回了未知的准备状态。",
                                 txmPresent: StikJIT.isTXMPresent)
                }
            case .enable:
                guard let targetPID = request.targetPID,
                      let scriptBase64 = request.scriptBase64, !scriptBase64.isEmpty else {
                    throw NSError(domain: "HengeJITHelper", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "缺少目标进程或 Henge 的 JIT 脚本。"])
                }
                try StikJIT.enableJIT(
                    targetPID: targetPID,
                    pairingFile: pairingURL,
                    ddiPaths: paths,
                    configuration: configuration,
                    script: .customBase64(scriptBase64),
                    forceScript: true,
                    preparationProgress: { NSLog("[HengeJIT] prepare: %@", String(describing: $0)) },
                    progress: { NSLog("[HengeJIT] %@", $0) })
                return .init(success: true, message: "Henge 已正常断开与内置 JIT 辅助进程的连接。" + portNote,
                             txmPresent: StikJIT.isTXMPresent)
            case .resetDDI:
                preconditionFailure("Handled above")
            }
        } catch {
            return .init(success: false, message: error.localizedDescription + portNote,
                         txmPresent: StikJIT.isTXMPresent)
        }
    }
}

/// NSExtensionPrincipalClass (Info.plist). The request arrives as JSON in the
/// first input item; the response goes back as JSON in the item the request
/// completes with. Enable completes only once Henge's script has detached, so
/// the request, and this process, last as long as the debugger does.
@objc(HengeJITHelperHandler)
final class HengeJITHelperHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let info = (context.inputItems.first as? NSExtensionItem)?.userInfo
        let data = info?[HengeJITRequest.itemKey] as? Data
        HengeJITWork.queue.async {
            let response: HengeJITRequest.Response
            if let data, let request = try? JSONDecoder().decode(HengeJITRequest.self, from: data) {
                response = HengeJITWork.handle(request)
            } else {
                response = .init(success: false, message: "Henge 的 JIT 辅助进程未收到请求。",
                                 txmPresent: nil)
            }
            let item = NSExtensionItem()
            item.userInfo = [HengeJITRequest.Response.itemKey: (try? JSONEncoder().encode(response)) ?? Data()]
            context.completeRequest(returningItems: [item], completionHandler: nil)
        }
    }
}
