import Foundation
import AppKit

enum CodexProcessError: Error, LocalizedError {
    case notFound
    case stillRunning
    case noFreePort
    case cdpNotReady
    case signatureInvalid

    var errorDescription: String? {
        switch self {
        case .notFound: return "未找到 Codex 桌面端（com.openai.codex）"
        case .stillRunning: return "Codex 未能退出，请先手动退出再试"
        case .noFreePort: return "没有可用的回环端口"
        case .cdpNotReady: return "Codex 调试端口 45 秒内未就绪（可能启动失败或被更新拒绝）"
        case .signatureInvalid: return "Codex 签名校验未通过（非 OpenAI 官方签名），已停止注入"
        }
    }
}

enum CodexProcess {
    static func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: CodexLocator.bundleID).isEmpty
    }

    /// Graceful quit, waiting up to `timeout` seconds.
    static func quit(timeout: TimeInterval = 15) async throws {
        guard isRunning() else { return }
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        script.arguments = ["-e", "tell application id \"\(CodexLocator.bundleID)\" to quit"]
        script.standardOutput = FileHandle.nullDevice
        script.standardError = FileHandle.nullDevice
        try? script.run()
        script.waitUntilExit()

        let deadline = Date().addingTimeInterval(timeout)
        while isRunning() && Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        if isRunning() { throw CodexProcessError.stillRunning }
    }

    /// Launch Codex with a loopback-only DevTools port. Never touches the app bundle.
    static func launchWithCDP(bundle: URL, port: Int) async throws {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [
            "-na", bundle.path, "--args",
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=\(port)",
        ]
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        try open.run()
        open.waitUntilExit()

        // Wait for the DevTools endpoint to come up (Codex cold start can take a while).
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if await CDP.httpReady(port: port) { return }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        throw CodexProcessError.cdpNotReady
    }

    static func launchNormally(bundle: URL) throws {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-na", bundle.path]
        try open.run()
        open.waitUntilExit()
    }

    /// First free loopback TCP port at or above `preferred`.
    static func freePort(preferred: Int = 9341, span: Int = 100) -> Int? {
        for candidate in preferred...min(preferred + span, 65535) {
            if portIsFree(candidate) { return candidate }
        }
        return nil
    }

    private static func portIsFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(fd, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
