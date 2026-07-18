import Foundation
import CodexAuraCore

/// Long-running loop that keeps the current theme injected into every verified
/// Codex renderer page on the DevTools port.
actor InjectionEngine {
    struct Status {
        var watching = false
        var injectedTargets = 0
        var lastError: String?
    }

    private let port: Int
    private var sessions: [String: CDPSession] = [:]
    private var earlyScriptIDs: [String: String] = [:]
    private var watchTask: Task<Void, Never>?
    private var currentPayload: String?
    private var currentThemeID: String?
    /// Reentrancy guard: actor methods interleave at await points, and two
    /// concurrent discoveries would open duplicate sessions for the same page.
    private var discoveryInFlight = false
    private(set) var status = Status()

    init(port: Int) {
        self.port = port
    }

    var activeThemeID: String? { currentThemeID }
    var activePort: Int { port }

    func startWatching() {
        guard watchTask == nil else { return }
        status.watching = true
        watchTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
    }

    func stopWatching() async {
        watchTask?.cancel()
        watchTask = nil
        status.watching = false
        // An in-flight discovery doesn't feel the cancellation (continuations
        // don't); wait for it to finish writing `sessions` before teardown,
        // otherwise its sessions leak with nobody left to close them.
        while discoveryInFlight {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await closeAllSessions()
    }

    /// Set (or change) the theme. Re-injects into every live Codex page — no restart.
    /// Throws unless at least one page both probes as Codex and passes the
    /// post-injection self-check: "applied" must never be a lie.
    /// - Returns: number of pages verified to carry the theme.
    @discardableResult
    func apply(theme: Theme) async throws -> Int {
        let payload = try PayloadBuilder.buildPayload(for: theme)
        let previousPayload = currentPayload
        let previousThemeID = currentThemeID
        currentPayload = payload
        currentThemeID = theme.id
        do {
            // Discover injects `currentPayload` into newly found pages; only pages
            // we already knew about still run the previous script and need a
            // refresh here.
            let preExisting = Set(sessions.keys)
            try await discoverWithRetry()
            for id in preExisting {
                guard let session = sessions[id] else { continue }
                do {
                    if let early = earlyScriptIDs[id] { await session.removeScriptOnNewDocument(early) }
                    try await session.evaluate(PayloadBuilder.unlockScript)
                    earlyScriptIDs[id] = try await session.addScriptOnNewDocument(payload)
                    try await session.evaluate(payload)
                } catch {
                    status.lastError = error.localizedDescription
                }
            }
            var verified = 0
            var firstError: Error?
            for (_, session) in sessions {
                do {
                    guard let report = try await session.evaluate(PayloadBuilder.verifyScript) as? [String: Any],
                          report["installed"] as? Bool == true,
                          report["stylePresent"] as? Bool == true,
                          report["themeId"] as? String == theme.id
                    else { continue }
                    verified += 1
                } catch {
                    if firstError == nil { firstError = error }
                    status.lastError = error.localizedDescription
                }
            }
            status.injectedTargets = verified
            guard verified > 0 else { throw firstError ?? CDPError.verifyFailed }
            return verified
        } catch {
            // Roll back: a theme the user was told "failed" must not keep
            // leaking into pages discovered by later ticks.
            currentPayload = previousPayload
            currentThemeID = previousThemeID
            throw error
        }
    }

    /// Attach to any live Codex pages without injecting anything (used by restore/screenshot).
    func attachOnce() async throws {
        try await discoverAndInject()
    }

    /// Live-tweak a CSS variable on every injected page (dim / blur / focus) and
    /// mirror it into localStorage so page reloads replay the same value (the
    /// payload re-reads it — otherwise tweaks silently revert on refresh).
    func setVariable(_ name: String, value: String) async {
        let script = """
        (() => {
          document.documentElement.style.setProperty(\(jsonString(name)), \(jsonString(value)));
          try {
            const key = 'codexaura:tweaks';
            const t = JSON.parse(localStorage.getItem(key) ?? '{}');
            t[\(jsonString(name))] = \(jsonString(value));
            t['aura-theme-id'] = \(jsonString(currentThemeID ?? ""));
            localStorage.setItem(key, JSON.stringify(t));
          } catch (e) {}
          return true;
        })()
        """
        for (_, session) in sessions {
            _ = try? await session.evaluate(script)
        }
    }

    /// Toggle bordered mode on every injected page without re-injecting.
    func setBordered(_ on: Bool) async {
        let flag = on ? "true" : "false"
        let script = """
        (() => {
          document.documentElement.classList.toggle('aura-bordered', \(flag));
          try {
            const key = 'codexaura:tweaks';
            const t = JSON.parse(localStorage.getItem(key) ?? '{}');
            t['aura-bordered'] = \(flag);
            t['aura-theme-id'] = \(jsonString(currentThemeID ?? ""));
            localStorage.setItem(key, JSON.stringify(t));
          } catch (e) {}
          return true;
        })()
        """
        for (_, session) in sessions {
            _ = try? await session.evaluate(script)
        }
    }

    /// Remove the skin from every page and stop touching them. Also attaches to
    /// pages this process never saw (e.g. after an app restart) so the cleanup —
    /// and its kill-switch against orphan early-scripts — reaches them too.
    func restoreOfficial() async {
        currentPayload = nil
        currentThemeID = nil
        try? await discoverAndInject()
        for (id, session) in sessions {
            if let early = earlyScriptIDs[id] { await session.removeScriptOnNewDocument(early) }
            _ = try? await session.evaluate(PayloadBuilder.cleanupScript)
        }
        earlyScriptIDs.removeAll()
    }

    func screenshot(to url: URL) async throws {
        if sessions.isEmpty { try await discoverAndInject() }
        guard let session = sessions.values.first else { throw CDPError.noCodexTarget }
        let data = try await session.captureScreenshotJPEG()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    // MARK: - Internals

    private func tick() async {
        do {
            try await discoverAndInject()
        } catch {
            status.lastError = error.localizedDescription
        }
    }

    /// Renderer DOM can lag behind the DevTools endpoint right after a (re)launch;
    /// probe failures there are transient, so give discovery a few chances.
    private func discoverWithRetry() async throws {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                try await discoverAndInject()
                return
            } catch {
                lastError = error
                if attempt < 2 { try? await Task.sleep(nanoseconds: 1_500_000_000) }
            }
        }
        throw lastError ?? CDPError.noCodexTarget
    }

    /// Discover Codex pages and inject the current payload into new ones.
    /// Throws when the DevTools endpoint is unreachable, when no Codex page
    /// exists at all, or when every candidate page fails the probe — callers
    /// (and users) must hear about it instead of a silent no-op.
    private func discoverAndInject() async throws {
        // Serialize against other discoverers (tick × apply): actor reentrancy
        // would otherwise let two runs open duplicate sessions for one page.
        while discoveryInFlight {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        discoveryInFlight = true
        defer { discoveryInFlight = false }

        let targets = try await CDP.listTargets(port: port)
        let activeIDs = Set(targets.map(\.id))

        // Drop sessions whose page went away.
        for (id, session) in sessions where !activeIDs.contains(id) {
            await session.close()
            sessions.removeValue(forKey: id)
            earlyScriptIDs.removeValue(forKey: id)
        }

        for target in targets where sessions[target.id] == nil {
            guard let session = try? CDPSession(target: target, port: port) else { continue }
            do {
                try await session.open()
                // Only touch pages that are really the Codex shell.
                guard let probe = try await session.evaluate(PayloadBuilder.probeScript) as? [String: Any],
                      probe["codex"] as? Bool == true else {
                    await session.close()
                    continue
                }
                if let payload = currentPayload {
                    try await session.evaluate(PayloadBuilder.unlockScript)
                    earlyScriptIDs[target.id] = try await session.addScriptOnNewDocument(payload)
                    try await session.evaluate(payload)
                }
                sessions[target.id] = session
            } catch {
                status.lastError = error.localizedDescription
                await session.close()
            }
        }
        status.injectedTargets = sessions.count
        if sessions.isEmpty {
            throw targets.isEmpty ? CDPError.noCodexTarget : CDPError.probeFailed
        }
    }

    private func closeAllSessions() async {
        for (_, session) in sessions { await session.close() }
        sessions.removeAll()
        earlyScriptIDs.removeAll()
        status.injectedTargets = 0
    }

    private func jsonString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
