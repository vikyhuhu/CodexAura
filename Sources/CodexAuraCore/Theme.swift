import Foundation

/// A CodexAura theme pack: a directory containing theme.json + a background image.
/// Compatible on read with Codex Dream Skin preset packs (same layout, superset colors).
public struct Theme: Codable, Identifiable, Hashable {
    public enum Appearance: String, Codable, Hashable {
        case auto
        case dark
        case light
    }

    public var schemaVersion: Int = 1
    public var revision: Int = 1
    public var id: String
    public var name: String
    public var image: String
    public var appearance: Appearance = .auto
    public var colors: Colors
    public var dim: Double = 0.25      // readability scrim opacity 0...0.8
    public var blur: Double = 0        // wallpaper blur in px 0...30
    public var contentMask: Double = 1 // content readability gradient strength 0...1
    public var focusX: Double = 0.5    // background focal point 0...1
    public var focusY: Double = 0.5

    public struct Colors: Codable, Hashable {
        public var background: String
        public var panel: String
        public var accent: String
        public var text: String
        public var muted: String
        public var line: String
        public var onAccent: String? = nil

        public init(background: String, panel: String, accent: String, text: String,
                    muted: String, line: String, onAccent: String? = nil) {
            self.background = background
            self.panel = panel
            self.accent = accent
            self.text = text
            self.muted = muted
            self.line = line
            self.onAccent = onAccent
        }
    }

    /// Directory on disk that contains this pack (not serialized).
    var directory: URL?

    enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, id, name, image, appearance, colors, dim, blur, contentMask, focusX, focusY
    }

    /// Decoding-only key for Dream Skin's nested `art` object (not encoded).
    private enum ExtraKeys: String, CodingKey { case art }

    public init(schemaVersion: Int = 1, revision: Int = 1, id: String, name: String, image: String,
                appearance: Appearance = .auto, colors: Colors,
                dim: Double = 0.25, blur: Double = 0, contentMask: Double = 1,
                focusX: Double = 0.5, focusY: Double = 0.5,
                directory: URL? = nil) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.id = id
        self.name = name
        self.image = image
        self.appearance = appearance
        self.colors = colors
        self.dim = dim
        self.blur = blur
        self.contentMask = contentMask
        self.focusX = focusX
        self.focusY = focusY
        self.directory = directory
    }

    public var imageURL: URL? { directory?.appendingPathComponent(image) }
    public var thumbnailURL: URL? {
        guard let directory else { return nil }
        let thumb = directory.appendingPathComponent("thumb.jpg")
        return FileManager.default.fileExists(atPath: thumb.path) ? thumb : imageURL
    }

    public var isBundledPreset: Bool {
        guard let directory else { return false }
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(Self.bundledMarkerName).path
        )
    }

    static let bundledMarkerName = ".codexaura-bundled"

    public static func load(from directory: URL) throws -> Theme {
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
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        image = try c.decode(String.self, forKey: .image)
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .auto
        colors = try c.decodeIfPresent(Colors.self, forKey: .colors) ?? Theme.fallbackColors
        dim = try c.decodeIfPresent(Double.self, forKey: .dim) ?? 0.25
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0
        contentMask = try c.decodeIfPresent(Double.self, forKey: .contentMask) ?? 1
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
    public static let fallbackColors = Colors(
        background: "#14161b", panel: "#1b1e24", accent: "#c98a9b",
        text: "#eceef2", muted: "#a2a8b0", line: "rgba(255,255,255,.14)"
    )
}

public enum ThemeError: Error, LocalizedError {
    case missingImage(String)
    case themeNotFound(String)
    case invalidPack
    case imageTooLarge
    case builtInTheme

    public var errorDescription: String? {
        switch self {
        case .missingImage(let id): return "主题 \(id) 缺少背景图"
        case .themeNotFound(let id): return "主题不存在：\(id)"
        case .invalidPack: return "不是有效的主题包（需要 theme.json + 背景图）"
        case .imageTooLarge: return "图片超出安全限制（16384px / 16MB）"
        case .builtInTheme: return "内置主题不能删除"
        }
    }
}
