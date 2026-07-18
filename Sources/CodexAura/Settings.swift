import Foundation

/// App-level display settings, shared between the menu bar app and the CLI
/// (UserDefaults would not be shared — CLI has no bundle id).
struct AuraSettings: Codable {
    /// true = 结构边界线模式；false = 无边界（默认，左右连续一张画）
    var bordered: Bool = false

    /// 首页大标题下方的用户签名行；空字符串 = 不显示
    var tagline: String = ""

    private static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("CodexAura/settings.json")
    }

    static func load() -> AuraSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(AuraSettings.self, from: data)
        else { return AuraSettings() }
        return settings
    }

    func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: url)
    }
}
