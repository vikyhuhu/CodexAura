import Foundation

/// A CodexAura theme pack: a directory containing theme.json + a background image.
/// Compatible on read with Codex Dream Skin preset packs (same layout, superset colors).
struct Theme: Codable, Identifiable, Hashable {
    var schemaVersion: Int = 1
    var id: String
    var name: String
    var image: String
    var colors: Colors
    var dim: Double = 0.25      // readability scrim opacity 0...0.8
    var blur: Double = 0        // wallpaper blur in px 0...30
    var focusX: Double = 0.5    // background focal point 0...1
    var focusY: Double = 0.5

    struct Colors: Codable, Hashable {
        var background: String
        var panel: String
        var accent: String
        var text: String
        var muted: String
        var line: String
    }

    /// Directory on disk that contains this pack (not serialized).
    var directory: URL?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, image, colors, dim, blur, focusX, focusY
    }

    /// Decoding-only key for Dream Skin's nested `art` object (not encoded).
    private enum ExtraKeys: String, CodingKey { case art }

    init(schemaVersion: Int = 1, id: String, name: String, image: String, colors: Colors,
         dim: Double = 0.25, blur: Double = 0, focusX: Double = 0.5, focusY: Double = 0.5,
         directory: URL? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.image = image
        self.colors = colors
        self.dim = dim
        self.blur = blur
        self.focusX = focusX
        self.focusY = focusY
        self.directory = directory
    }

    var imageURL: URL? { directory?.appendingPathComponent(image) }
    var thumbnailURL: URL? {
        guard let directory else { return nil }
        let thumb = directory.appendingPathComponent("thumb.jpg")
        return FileManager.default.fileExists(atPath: thumb.path) ? thumb : imageURL
    }

    static func load(from directory: URL) throws -> Theme {
        let configURL = directory.appendingPathComponent("theme.json")
        let data = try Data(contentsOf: configURL)
        var theme = try JSONDecoder().decode(Theme.self, from: data)
        // The artwork must live inside the pack: no subdirectories, no escapes.
        guard !theme.image.isEmpty,
              !theme.image.contains("/"), !theme.image.contains("\\"), !theme.image.contains("..")
        else { throw ThemeError.invalidPack }
        theme.directory = directory
        guard theme.imageURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true else {
            throw ThemeError.missingImage(directory.lastPathComponent)
        }
        return theme
    }

    /// Tolerant decode for Dream Skin preset theme.json: colors may be absent
    /// (they auto-derive them at runtime) and focus may be nested under `art`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        image = try c.decode(String.self, forKey: .image)
        colors = try c.decodeIfPresent(Colors.self, forKey: .colors) ?? Theme.fallbackColors
        dim = try c.decodeIfPresent(Double.self, forKey: .dim) ?? 0.25
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0
        if let fx = try c.decodeIfPresent(Double.self, forKey: .focusX),
           let fy = try c.decodeIfPresent(Double.self, forKey: .focusY) {
            focusX = fx; focusY = fy
        } else if let art = try? decoder.container(keyedBy: ExtraKeys.self).decode(Art.self, forKey: .art) {
            focusX = art.focusX ?? 0.5
            focusY = art.focusY ?? 0.5
        } else {
            focusX = 0.5; focusY = 0.5
        }
    }

    private struct Art: Codable { var focusX: Double?; var focusY: Double? }

    /// Used when a pack ships no explicit colors (Dream Skin auto-derived ones).
    static let fallbackColors = Colors(
        background: "#14161b", panel: "#1b1e24", accent: "#c98a9b",
        text: "#eceef2", muted: "#a2a8b0", line: "rgba(255,255,255,.14)"
    )
}

enum ThemeError: Error, LocalizedError {
    case missingImage(String)
    case themeNotFound(String)
    case invalidPack
    case imageTooLarge

    var errorDescription: String? {
        switch self {
        case .missingImage(let id): return "主题 \(id) 缺少背景图"
        case .themeNotFound(let id): return "主题不存在：\(id)"
        case .invalidPack: return "不是有效的主题包（需要 theme.json + 背景图）"
        case .imageTooLarge: return "图片超出安全限制（16384px / 16MB）"
        }
    }
}
