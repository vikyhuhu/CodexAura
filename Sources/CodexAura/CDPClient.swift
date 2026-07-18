import Foundation

enum CDPError: Error, LocalizedError {
    case badTargetList
    case invalidWebSocketURL
    case noCodexTarget
    case probeFailed
    case verifyFailed
    case commandFailed(String)
    case socketClosed
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .badTargetList: return "CDP 目标列表不可用"
        case .invalidWebSocketURL: return "拒绝了非回环的 CDP WebSocket 地址"
        case .noCodexTarget: return "没有找到 Codex 渲染页面（确认 Codex 已用调试端口启动）"
        case .probeFailed: return "页面探针未通过：未找到 Codex 主界面（可能仍在启动中，或界面结构已变更）"
        case .verifyFailed: return "注入后自检未通过（样式未生效）"
        case .commandFailed(let m): return "CDP 命令失败: \(m)"
        case .socketClosed: return "CDP 连接已关闭"
        case .timeout(let m): return "CDP 命令超时: \(m)"
        }
    }
}

struct CDPTarget: Decodable {
    let id: String
    let type: String
    let url: String
    let title: String?
    let webSocketDebuggerUrl: String?
}

enum CDP {
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "[::1]"]

    /// Validate the DevTools WebSocket URL shape: loopback only, expected port,
    /// `/devtools/page/<id>` path, no credentials/query/fragment.
    static func validatedWebSocketURL(_ raw: String, port: Int) throws -> URL {
        guard let url = URL(string: raw),
              url.scheme == "ws",
              let host = url.host, loopbackHosts.contains(host),
              url.port == port,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.range(of: #"^/devtools/page/[A-Za-z0-9._-]{1,200}$"#, options: .regularExpression) != nil
        else { throw CDPError.invalidWebSocketURL }
        return url
    }

    static func listTargets(port: Int) async throws -> [CDPTarget] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else { throw CDPError.badTargetList }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CDPError.badTargetList }
        let targets = try JSONDecoder().decode([CDPTarget].self, from: data)
        return targets.filter { target in
            guard target.type == "page",
                  target.url.hasPrefix("app://"),
                  let ws = target.webSocketDebuggerUrl,
                  let _ = try? validatedWebSocketURL(ws, port: port)
            else { return false }
            return true
        }
    }

    /// Strict readiness: 200 + a real DevTools /json/version payload, so a random
    /// HTTP service squatting on the port is not mistaken for Codex.
    static func httpReady(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/version") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["Browser"] is String
        else { return false }
        return true
    }
}

/// One DevTools page session over a loopback WebSocket.
actor CDPSession {
    private let task: URLSessionWebSocketTask
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var receiveTask: Task<Void, Never>?
    private(set) var closed = false

    init(target: CDPTarget, port: Int) throws {
        let wsURL = try CDP.validatedWebSocketURL(target.webSocketDebuggerUrl ?? "", port: port)
        self.task = URLSession.shared.webSocketTask(with: wsURL)
        // Default is 1MB — too small for screenshots and base64 artwork payloads.
        self.task.maximumMessageSize = 64 * 1024 * 1024
    }

    func open() async throws {
        task.resume()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await self.task.receive()
                    await self.handle(message)
                } catch {
                    await self.failAll(error)
                    return
                }
            }
        }
        _ = try await send("Runtime.enable")
        _ = try await send("Page.enable")
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        guard let id = object["id"] as? Int else { return } // events are ignored
        cancelTimeout(id)
        guard let waiter = pending.removeValue(forKey: id) else { return }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown"
            waiter.resume(throwing: CDPError.commandFailed(message))
        } else {
            waiter.resume(returning: object["result"] as? [String: Any] ?? [:])
        }
    }

    private func failAll(_ error: Error) {
        closed = true
        for (_, waiter) in pending { waiter.resume(throwing: error) }
        pending.removeAll()
        for (_, task) in timeoutTasks { task.cancel() }
        timeoutTasks.removeAll()
    }

    /// Sends a command and awaits its response, giving up after `timeout` seconds.
    /// Without this a stalled renderer would park the continuation (and the whole
    /// app via `busy`) forever.
    @discardableResult
    func send(_ method: String, params: [String: Any] = [:], timeout: TimeInterval = 15) async throws -> [String: Any] {
        if closed { throw CDPError.socketClosed }
        let id = nextID
        nextID += 1
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(decoding: data, as: UTF8.self)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeoutTasks[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                // takePending wins the race against a late response: whoever
                // removes the continuation first resumes it.
                if let waiter = await self.takePending(id) {
                    waiter.resume(throwing: CDPError.timeout(method))
                }
            }
            task.send(.string(text)) { [weak self] error in
                if let error {
                    Task { [weak self] in
                        guard let self else { return }
                        if let waiter = await self.takePending(id) {
                            waiter.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }

    private func takePending(_ id: Int) -> CheckedContinuation<[String: Any], Error>? {
        cancelTimeout(id)
        return pending.removeValue(forKey: id)
    }

    private func cancelTimeout(_ id: Int) {
        timeoutTasks.removeValue(forKey: id)?.cancel()
    }

    /// Evaluate a JS expression in the page; returns the JSON value of the result.
    @discardableResult
    func evaluate(_ expression: String) async throws -> Any? {
        let result = try await send("Runtime.evaluate", params: [
            "expression": expression,
            "awaitPromise": true,
            "returnByValue": true,
        ])
        if let exception = result["exceptionDetails"] as? [String: Any] {
            let detail = (exception["exception"] as? [String: Any])?["description"] as? String
                ?? exception["text"] as? String ?? "evaluation failed"
            throw CDPError.commandFailed(detail)
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    /// Register a script to run on every new document (survives reloads).
    @discardableResult
    func addScriptOnNewDocument(_ source: String) async throws -> String? {
        let result = try await send("Page.addScriptToEvaluateOnNewDocument", params: ["source": source])
        return result["identifier"] as? String
    }

    func removeScriptOnNewDocument(_ identifier: String) async {
        _ = try? await send("Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": identifier])
    }

    /// JPEG screenshots stay small enough for the WebSocket message size limit.
    func captureScreenshotJPEG(quality: Int = 70) async throws -> Data {
        let result = try await send("Page.captureScreenshot", params: [
            "format": "jpeg", "quality": quality, "fromSurface": true, "captureBeyondViewport": false,
        ], timeout: 30)
        guard let base64 = result["data"] as? String, let data = Data(base64Encoded: base64) else {
            throw CDPError.commandFailed("screenshot decode failed")
        }
        return data
    }

    func close() {
        closed = true
        receiveTask?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        for (_, waiter) in pending { waiter.resume(throwing: CDPError.socketClosed) }
        pending.removeAll()
        for (_, timeoutTask) in timeoutTasks { timeoutTask.cancel() }
        timeoutTasks.removeAll()
    }
}
