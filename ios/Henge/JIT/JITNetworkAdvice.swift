// Simplified Chinese translation, 2026-11-09.
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// What the current network path offers, copied from NWPath by the app so this file stays Foundation-only.
struct NetworkPathSnapshot: Equatable {
    var isSatisfied: Bool
    var usesWiFi: Bool
    var usesCellular: Bool
    var usesWired: Bool
}

enum NetworkSituation: Equatable {
    case wifi
    case cellularOnly
    case wired
    case offline

    init(_ path: NetworkPathSnapshot) {
        if !path.isSatisfied {
            self = .offline
        } else if path.usesWiFi {
            self = .wifi
        } else if path.usesWired {
            self = .wired
        } else {
            // A satisfied path with no known interface type is not the cellular case: it keeps the plain VPN advice.
            self = path.usesCellular ? .cellularOnly : .wifi
        }
    }
}

/// What the user can be offered to do next.
enum JITAdviceAction: Equatable {
    case connectLocalDevVPN
    case pairAgain
}

struct JITAdvice: Equatable {
    var message: String
    var actions: [JITAdviceAction]
}

/// Why the built-in helper could not reach this device, read from its error text.
enum JITConnectionProblem: Equatable {
    /// Nothing answered at LocalDevVPN's address: the VPN is off or not routing, or iOS sent the connection elsewhere.
    case unreachable
    /// The device closed the connection, usually because it no longer accepts
    /// this pairing (every new pairing replaces the last).
    case pairing

    init?(helperMessage: String) {
        let text = helperMessage.lowercased()
        let has = { (needles: [String]) in needles.contains(where: text.contains) }
        if has(["connectionreset", "connection reset", "device refused connection"]) {
            self = .pairing
        } else if has(["connectionrefused", "connection refused", "timedout", "timed out",
                       "networkunreachable", "network unreachable", "hostunreachable",
                       "host unreachable", "no route"]) {
            self = .unreachable
        } else {
            return nil
        }
    }
}

enum JITNetworkAdvice {
    static func advice(forHelperMessage helperMessage: String, situation: NetworkSituation) -> JITAdvice? {
        guard let problem = JITConnectionProblem(helperMessage: helperMessage) else { return nil }
        if problem == .pairing {
            return JITAdvice(
                message: "设备关闭了连接，通常是因为它已不再接受 "
                       + "Henge 的配对。请重新配对，并确认 LocalDevVPN 已连接。",
                actions: [.pairAgain, .connectLocalDevVPN])
        }
        guard situation == .cellularOnly else {
            return JITAdvice(message: "Henge 无法连接此设备。请连接 LocalDevVPN 后重试。",
                             actions: [.connectLocalDevVPN])
        }
        return JITAdvice(
            message: "即使 LocalDevVPN 显示已连接，iOS 仍可能通过蜂窝网络发送 Henge 的连接请求。"
                   + "请在控制中心关闭蜂窝数据，等待 2 秒后重新开启。"
                   + "也可以尝试连接一次 Wi-Fi 或热点。"
                   + "请保持 LocalDevVPN 已连接，关闭 Tailscale 等其他 VPN 后重试。",
            actions: [.connectLocalDevVPN])
    }
}

enum JITRetryDecision: Equatable {
    case retry(after: TimeInterval)
    case giveUp
}

/// Whether to try the helper again by itself after it failed to connect.
///
/// On cellular, iOS tends to send the first connection to 10.7.0.1 out over the mobile network instead of through
/// LocalDevVPN, and later ones go through. So an unreachable error on cellular is retried: at most 2 retries (3
/// attempts in all), 4 seconds apart -- long enough for the routing to settle, short enough to feel like one try.
enum JITRetryPolicy {
    static let maxAttempts = 3

    /// Shown while waiting to try attempt `nextAttempt` (the first retry is attempt 2).
    static func statusText(nextAttempt: Int) -> String {
        "正在通过 LocalDevVPN 重试（第 \(nextAttempt)/\(maxAttempts) 次）…"
    }

    static func decision(situation: NetworkSituation, problem: JITConnectionProblem, attempt: Int) -> JITRetryDecision {
        guard situation == .cellularOnly, problem == .unreachable else { return .giveUp }
        return attempt < maxAttempts ? .retry(after: 4) : .giveUp
    }
}
