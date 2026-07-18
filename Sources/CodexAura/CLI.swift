import Foundation
import AppKit

/// Headless commands: `CodexAura --cli <command>`. Used for development and
/// debugging without touching the menu bar app.
enum CLI {
    static func run(_ args: [String]) async -> Int32 {
        guard let command = args.first else {
            print(usage)
            return 64
        }
        let flags = parseFlags(Array(args.dropFirst()))
        let port = flags.int("port") ?? 9341

        do {
            switch command {
            case "doctor":
                return doctor()
            case "launch":
                try await launch(port: port, restart: false)
            case "restart":
                try await launch(port: port, restart: true)
            case "apply":
                let theme = try resolveTheme(flags)
                guard let info = CodexLocator.locate() else { throw CodexProcessError.notFound }
                guard info.signatureValid else { throw CodexProcessError.signatureInvalid }
                let engine = InjectionEngine(port: port)
                try await engine.apply(theme: theme)
                print("已注入主题: \(theme.name) [\(theme.id)] (端口 \(port))")
                if let out = flags.string("shot") {
                    try await engine.screenshot(to: URL(fileURLWithPath: out))
                    print("截图: \(out)")
                }
            case "shot":
                guard let out = flags.string("out") else {
                    print("用法: shot --out <路径>")
                    return 64
                }
                let engine = InjectionEngine(port: port)
                try await engine.screenshot(to: URL(fileURLWithPath: out))
                print("截图: \(out)")
            case "restore":
                let engine = InjectionEngine(port: port)
                try await engine.attachOnce() // 仅附着会话，不注入
                await engine.restoreOfficial()
                print("已还原官方外观")
            case "borders":
                guard let value = args.dropFirst().first, ["on", "off"].contains(value) else {
                    print("用法: borders on|off")
                    return 64
                }
                var settings = AuraSettings.load()
                settings.bordered = (value == "on")
                settings.save()
                let engine = InjectionEngine(port: port)
                try await engine.attachOnce()
                await engine.setBordered(settings.bordered)
                print("边界线: \(settings.bordered ? "开" : "关")")
            case "tagline":
                let text = flags.string("text") ?? ""
                var settings = AuraSettings.load()
                settings.tagline = text
                settings.save()
                let engine = InjectionEngine(port: port)
                try await engine.attachOnce()
                let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed])) ?? Data()
                await engine.setVariable("--aura-tagline", value: String(decoding: data, as: UTF8.self))
                print("签名: \(text.isEmpty ? "（已清空）" : text)")
            case "eval":                guard let script = flags.string("js") else { print("用法: eval --js <表达式>"); return 64 }
                let result = try await evalOnCodex(script, port: port)
                print(result ?? "undefined")
            case "themes":
                for theme in ThemeLibrary.shared.listThemes() {
                    print("\(theme.id)\t\(theme.name)")
                }
            case "seed":
                print("生成内置预设: \(ThemeLibrary.shared.seedBuiltInPresets()) 个")
            case "import-image":
                guard let path = flags.string("path") else { print("用法: import-image --path <图片> [--name <名>]"); return 64 }
                let theme = try ThemeLibrary.shared.importImage(
                    from: URL(fileURLWithPath: path), name: flags.string("name"))
                print("已导入: \(theme.id) \(theme.name)")
            case "import-presets":
                print("导入 Dream Skin 预设: \(ThemeLibrary.shared.importAllDreamSkinPresets()) 个")
            default:
                print("未知命令: \(command)\n\(usage)")
                return 64
            }
            return 0
        } catch {
            FileHandle.standardError.write("错误: \(error.localizedDescription)\n".data(using: .utf8)!)
            return 1
        }
    }

    private static let usage = """
    CodexAura CLI:
      doctor                              检查 Codex 安装与签名
      launch [--port N]                   带调试端口启动 Codex
      restart [--port N]                  重启 Codex 并带调试端口
      apply --theme <id> [--port N] [--shot out.png]   注入主题
      shot --out <路径> [--port N]        截取 Codex 窗口
      restore [--port N]                  还原官方外观
      themes                              列出主题库
      seed                                生成内置渐变预设
      import-image --path <图> [--name]   导入图片为主题
      import-presets                      导入本机 Dream Skin 预设
    """

    // MARK: - Commands

    private static func doctor() -> Int32 {
        guard let info = CodexLocator.locate() else {
            print("未找到 Codex 桌面端（com.openai.codex）")
            return 1
        }
        print("Codex: \(info.bundleURL.path)")
        print("版本: \(info.version)")
        let team = info.teamID ?? "无"
        let signatureLine = info.signatureValid ? "有效 (TeamID \(team))" : "校验未通过 (TeamID \(team))"
        print("签名: \(signatureLine)")
        print("运行中: \(CodexProcess.isRunning() ? "是" : "否")")
        return info.signatureValid ? 0 : 2
    }

    private static func launch(port: Int, restart: Bool) async throws {
        guard let info = CodexLocator.locate() else { throw CodexProcessError.notFound }
        guard info.signatureValid else { throw CodexProcessError.signatureInvalid }
        if CodexProcess.isRunning() {
            if !restart {
                print("Codex 已在运行；如需开启换肤请用 restart（会退出当前 Codex）")
                return
            }
            print("正在退出 Codex…")
            try await CodexProcess.quit()
        }
        guard let actualPort = CodexProcess.freePort(preferred: port) else { throw CodexProcessError.noFreePort }
        print("正在启动 Codex（调试端口 \(actualPort)）…")
        try await CodexProcess.launchWithCDP(bundle: info.bundleURL, port: actualPort)
        print("Codex 已启动")
    }

    private static func resolveTheme(_ flags: Flags) throws -> Theme {
        if let dir = flags.string("theme-dir") {
            return try Theme.load(from: URL(fileURLWithPath: dir))
        }
        guard let id = flags.string("theme") else {
            throw ThemeError.invalidPack
        }
        guard let theme = ThemeLibrary.shared.listThemes().first(where: { $0.id == id }) else {
            throw ThemeError.themeNotFound(id)
        }
        return theme
    }

    private static func evalOnCodex(_ script: String, port: Int) async throws -> Any? {
        let targets = try await CDP.listTargets(port: port)
        for target in targets {
            guard let session = try? CDPSession(target: target, port: port) else { continue }
            try? await session.open()
            if let probe = try? await session.evaluate(PayloadBuilder.probeScript) as? [String: Any],
               probe["codex"] as? Bool == true {
                let value = try await session.evaluate(script)
                await session.close()
                if let value, let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .fragmentsAllowed]) {
                    return String(decoding: data, as: UTF8.self)
                }
                return value
            }
            await session.close()
        }
        throw CDPError.noCodexTarget
    }

    // MARK: - Flag parsing

    struct Flags {        let values: [String: String]
        func string(_ key: String) -> String? { values[key] }
        func int(_ key: String) -> Int? { values[key].flatMap(Int.init) }
    }

    static func parseFlags(_ args: [String]) -> Flags {
        var values: [String: String] = [:]
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--"), index + 1 < args.count {
                values[String(arg.dropFirst(2))] = args[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        return Flags(values: values)
    }
}
