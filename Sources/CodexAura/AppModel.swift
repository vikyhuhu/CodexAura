import Foundation
import AppKit
import CodexAuraCore

@MainActor
final class AppModel: ObservableObject {
    enum CodexState: Equatable {
        case unknown
        case notInstalled
        case signatureInvalid   // found, but failed codesign / TeamID verification
        case notRunning
        case runningNoCDP      // running without the debug port — needs a restart to theme
        case ready             // CDP endpoint reachable
    }

    @Published var codexState: CodexState = .unknown
    @Published var codexVersion: String = ""
    @Published var themes: [Theme] = []
    @Published var activeThemeID: String?
    @Published var statusLine: String = "正在检查 Codex…"
    @Published var busy = false

    // Live tuning for the active theme (persisted back to theme.json).
    @Published var dim: Double = 0.25 { didSet { liveTweak("--aura-dim", String(dim)) } }
    @Published var blur: Double = 0 { didSet { liveTweak("--aura-blur", "\(blur)px") } }

    /// 「边界线」开关：持久化到设置文件，并实时切所有已注入页面。
    @Published var bordered: Bool = AuraSettings.load().bordered {
        didSet {
            var settings = AuraSettings.load()
            settings.bordered = bordered
            settings.save()
            Task { await engine?.setBordered(bordered) }
        }
    }

    /// 首页标题下方的签名行：持久化 + 实时更新（CSS content 需要带引号的值）。
    @Published var tagline: String = AuraSettings.load().tagline {
        didSet {
            var settings = AuraSettings.load()
            settings.tagline = tagline
            settings.save()
            let data = (try? JSONSerialization.data(withJSONObject: tagline, options: [.fragmentsAllowed])) ?? Data()
            let quoted = String(decoding: data, as: UTF8.self)
            Task { await engine?.setVariable("--aura-tagline", value: quoted) }
        }
    }

    private var codexInfo: CodexAppInfo?
    private var port: Int = 9341
    private var engine: InjectionEngine?
    private var tweakWorkItem: DispatchWorkItem?

    /// 弹出系统文件框之前先关掉菜单面板窗口：MenuBarExtra 没有程序化关闭的
    /// 绑定，只能把高层级浮窗直接 orderOut，否则文件框会被菜单压住。
    private func dismissFloatingPanels() {
        for window in NSApplication.shared.windows
        where window.isVisible && window.level.rawValue > NSWindow.Level.normal.rawValue {
            window.orderOut(nil)
        }
    }

    init() {
        ThemeLibrary.shared.seedBuiltInPresets()
        _ = try? BundledPresetCatalog().install(into: ThemeLibrary.shared)
        reloadThemes()
        Task { await refresh() }
    }

    // MARK: - Status

    func refresh() async {
        reloadThemes()
        // codesign verification spawns subprocesses and can take seconds —
        // keep it off the main actor so the menu doesn't freeze.
        let info = await Task.detached(priority: .userInitiated) { CodexLocator.locate() }.value
        guard let info else {
            codexInfo = nil
            codexState = .notInstalled
            statusLine = "未找到 Codex 桌面端"
            return
        }
        codexInfo = info
        codexVersion = info.version
        guard info.signatureValid else {
            codexState = .signatureInvalid
            statusLine = "Codex 签名校验未通过，已禁用换肤"
            return
        }
        guard CodexProcess.isRunning() else {
            codexState = .notRunning
            statusLine = "Codex 未运行"
            return
        }
        if await CDP.httpReady(port: port) {
            codexState = .ready
            statusLine = "Codex \(info.version) · 调试端口已连接"
        } else {
            codexState = .runningNoCDP
            statusLine = "Codex 运行中（未开调试端口）"
        }
    }

    // MARK: - Theme actions

    func apply(_ theme: Theme) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await performApply(theme)
    }

    /// Shared apply path (including the restart-then-reapply flow) — no busy
    /// guard here; callers serialize through `busy`.
    private func performApply(_ theme: Theme) async {
        do {
            // First click can land before the initial refresh finished.
            if codexInfo == nil { await refresh() }
            try requireValidSignature()
            if codexState != .ready { try await ensureCodexWithCDP() }
            let engine = try await ensureEngine()
            let injected = try await engine.apply(theme: theme)
            await engine.startWatching()
            // Re-assert the bordered setting so the pages' localStorage mirror
            // can't override a newer settings.json with an older value.
            await engine.setBordered(bordered)
            activeThemeID = theme.id
            dim = theme.dim
            blur = theme.blur
            statusLine = "已应用：\(theme.name)（\(injected) 个页面）"
        } catch {
            // The endpoint may have died (Codex quit, port squatted) — refresh so
            // the state machine degrades and the next click takes the restart path.
            await refresh()
            statusLine = "应用失败：\(error.localizedDescription)"
        }
    }

    func restore() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        // Use the live engine, or a throwaway one, so cleanup also reaches pages
        // a previous CodexAura run skinned (their orphan early-scripts get
        // neutralized by the kill-switch in the cleanup script).
        let target = engine ?? InjectionEngine(port: port)
        await target.restoreOfficial()
        await target.stopWatching()
        engine = nil
        activeThemeID = nil
        await refresh()
        // After refresh(), so the success message isn't overwritten by it.
        statusLine = "已还原官方外观"
    }

    /// Restart Codex with the debug port, then re-apply the active theme if any.
    func restartCodex() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try requireValidSignature()
            try await ensureCodexWithCDP(forceRestart: true)
            statusLine = "Codex 已重启，可以应用主题"
            if let id = activeThemeID, let theme = themes.first(where: { $0.id == id }) {
                await performApply(theme)
            }
        } catch {
            await refresh()
            statusLine = "重启失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Library actions

    func importImage() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .webP]
        panel.allowsMultipleSelection = false
        dismissFloatingPanels()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let theme = try ThemeLibrary.shared.importImage(from: url)
            reloadThemes()
            statusLine = "已导入主题：\(theme.name)"
            await apply(theme)
        } catch {
            statusLine = "导入失败：\(error.localizedDescription)"
        }
    }

    func importPack() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        dismissFloatingPanels()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let theme = try ThemeLibrary.shared.importPack(from: url)
            reloadThemes()
            statusLine = "已导入主题包：\(theme.name)"
        } catch {
            statusLine = "导入失败：\(error.localizedDescription)"
        }
    }

    func exportPack(_ theme: Theme) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(theme.id).zip"
        dismissFloatingPanels()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ThemeLibrary.shared.exportPack(theme, to: url)
            statusLine = "已导出：\(url.lastPathComponent)"
        } catch {
            statusLine = "导出失败：\(error.localizedDescription)"
        }
    }

    func importDreamSkinPresets() {
        let count = ThemeLibrary.shared.importAllDreamSkinPresets()
        reloadThemes()
        statusLine = count > 0 ? "已导入 \(count) 个 Dream Skin 预设" : "未找到本机 Dream Skin 预设"
    }

    func deleteTheme(_ theme: Theme) {
        // Don't race an in-flight apply/restore — the restore triggered for the
        // active theme would be silently dropped by the busy guard.
        guard !busy else {
            statusLine = "正在应用/还原，请稍后再删除"
            return
        }
        let wasActive = activeThemeID == theme.id
        do {
            try ThemeLibrary.shared.delete(theme)
        } catch {
            statusLine = error.localizedDescription
            return
        }
        reloadThemes()
        // Deleting the active theme must also pull it off the pages — otherwise
        // the watcher keeps injecting a theme that no longer exists on disk.
        if wasActive { Task { await restore() } }
    }

    func persistTuning() {
        guard let id = activeThemeID,
              var theme = themes.first(where: { $0.id == id }) else { return }
        theme.dim = dim
        theme.blur = blur
        try? ThemeLibrary.shared.save(theme)
        reloadThemes()
    }

    // MARK: - Internals

    func reloadThemes() {
        themes = ThemeLibrary.shared.listThemes()
    }

    private func ensureCodexWithCDP(forceRestart: Bool = false) async throws {
        guard let bundleURL = codexInfo?.bundleURL else { throw CodexProcessError.notFound }
        if !forceRestart, CodexProcess.isRunning(), await CDP.httpReady(port: port) {
            codexState = .ready
            return
        }
        if CodexProcess.isRunning() {
            statusLine = "正在重启 Codex 以开启调试端口…"
            // quit()/launch spawn osascript/open and block on them — keep that
            // off the main actor.
            try await Task.detached(priority: .userInitiated) { try await CodexProcess.quit() }.value
        }
        guard let selectedPort = CodexProcess.freePort(preferred: 9341) else {
            throw CodexProcessError.noFreePort
        }
        port = selectedPort
        try await Task.detached(priority: .userInitiated) {
            try await CodexProcess.launchWithCDP(bundle: bundleURL, port: selectedPort)
        }.value
        codexState = .ready
    }

    private func ensureEngine() async throws -> InjectionEngine {
        if let engine, await engine.activePort == port { return engine }
        // The port changed since the engine was created (e.g. 9341 was squatted
        // while Codex was down) — a stale engine would fail on every apply.
        await engine?.stopWatching()
        let created = InjectionEngine(port: port)
        engine = created
        return created
    }

    private func requireValidSignature() throws {
        guard let info = codexInfo else { throw CodexProcessError.notFound }
        guard info.signatureValid else { throw CodexProcessError.signatureInvalid }
    }

    private func liveTweak(_ name: String, _ value: String) {
        tweakWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { await self.engine?.setVariable(name, value: value) }
        }
        tweakWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }
}
