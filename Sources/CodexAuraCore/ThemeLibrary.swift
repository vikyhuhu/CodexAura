import Foundation
import AppKit

/// On-disk theme store: ~/Library/Application Support/CodexAura/Themes/<id>/
public final class ThemeLibrary {
    public static let shared = ThemeLibrary()

    public let rootURL: URL
    private let fm = FileManager.default

    public init(rootURL: URL? = nil) {
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.rootURL = rootURL ?? support.appendingPathComponent("CodexAura/Themes", isDirectory: true)
    }

    public func listThemes() -> [Theme] {
        guard let entries = try? fm.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { try? Theme.load(from: $0) }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: - Import an image as a new theme

    @discardableResult
    public func importImage(from sourceURL: URL, name: String? = nil) throws -> Theme {
        guard let image = NSImage(contentsOf: sourceURL) else { throw ThemeError.invalidPack }
        // Second-resolution timestamps collide on quick consecutive imports — add a suffix.
        let themeID = "custom-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6).lowercased())"
        let themeName = name?.trimmingCharacters(in: .whitespaces).nonEmpty
            ?? sourceURL.deletingPathExtension().lastPathComponent
        let dir = rootURL.appendingPathComponent(themeID, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Normalize: aspect-fill crop to 2560x1440 JPEG around the focal point.
        guard let bgData = ImageTools.normalizedWallpaperJPEG(image, maxSize: NSSize(width: 2560, height: 1440)) else {
            throw ThemeError.invalidPack
        }
        try bgData.write(to: dir.appendingPathComponent("background.jpg"))
        if let thumb = ImageTools.thumbnailJPEG(image, size: NSSize(width: 480, height: 270)) {
            try thumb.write(to: dir.appendingPathComponent("thumb.jpg"))
        }

        let palette = PaletteExtractor.palette(for: image)
        let theme = Theme(
            id: themeID, name: themeName, image: "background.jpg",
            colors: Theme.Colors(
                background: palette.background, panel: palette.panel, accent: palette.accent,
                text: palette.text, muted: palette.muted, line: palette.line
            )
        )
        try save(theme, to: dir)
        return try Theme.load(from: dir)
    }

    // MARK: - Import a Dream Skin preset pack directory

    @discardableResult
    public func importDreamSkinPreset(from presetDir: URL) throws -> Theme {
        // If the source pack ships no explicit colors, derive them from the image.
        let rawJSON = (try? Data(contentsOf: presetDir.appendingPathComponent("theme.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let hasExplicitColors = rawJSON?["colors"] is [String: Any]

        var theme = try Theme.load(from: presetDir) // tolerant decoder handles their format
        guard let sourceImage = theme.imageURL, let image = NSImage(contentsOf: sourceImage) else {
            throw ThemeError.missingImage(theme.id)
        }
        if !hasExplicitColors {
            let palette = PaletteExtractor.palette(for: image)
            theme.colors = Theme.Colors(
                background: palette.background, panel: palette.panel, accent: palette.accent,
                text: palette.text, muted: palette.muted, line: palette.line
            )
        }
        let dir = rootURL.appendingPathComponent(try Self.validatedThemeID(theme.id), isDirectory: true)
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Re-encode as a clean 2560x1440 JPEG so payloads stay small and uniform.
        guard let bgData = ImageTools.normalizedWallpaperJPEG(image, maxSize: NSSize(width: 2560, height: 1440)) else {
            throw ThemeError.invalidPack
        }
        try bgData.write(to: dir.appendingPathComponent("background.jpg"))
        if let thumb = ImageTools.thumbnailJPEG(image, size: NSSize(width: 480, height: 270)) {
            try thumb.write(to: dir.appendingPathComponent("thumb.jpg"))
        }
        theme.image = "background.jpg"
        try save(theme, to: dir)
        return try Theme.load(from: dir)
    }

    public func importAllDreamSkinPresets() -> Int {
        let presetsRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/codex-dream-skin-studio/presets", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: presetsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for dir in entries where dir.lastPathComponent.hasPrefix("preset-") {
            if (try? importDreamSkinPreset(from: dir)) != nil { count += 1 }
        }
        return count
    }

    /// Theme ids become directory names; packs from third parties are untrusted,
    /// so reject anything that could escape the Themes root (../, slashes, ...).
    private static func validatedThemeID(_ id: String) throws -> String {
        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$"#, options: .regularExpression) != nil,
              !id.contains("..")
        else { throw ThemeError.invalidPack }
        return id
    }

    // MARK: - Theme pack export / import (.zip)

    public func exportPack(_ theme: Theme, to destination: URL) throws {
        guard let dir = theme.directory else { throw ThemeError.invalidPack }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", dir.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ThemeError.invalidPack }
    }

    @discardableResult
    public func importPack(from zipURL: URL) throws -> Theme {
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, temp.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ThemeError.invalidPack }

        // The pack may unzip as <id>/theme.json or bare theme.json.
        let candidates = (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let packDir = candidates.first(where: {
            fm.fileExists(atPath: $0.appendingPathComponent("theme.json").path)
        }) ?? (fm.fileExists(atPath: temp.appendingPathComponent("theme.json").path) ? temp : nil)
        guard let packDir else { throw ThemeError.invalidPack }

        var theme = try Theme.load(from: packDir)
        let themeID = try Self.validatedThemeID(theme.id)
        // Never copy the pack directory as-is: a malicious pack can point `image`
        // outside the pack (../../.ssh/id_rsa) or use a symlink as the artwork —
        // both would smuggle arbitrary local files into the injected payload.
        // Re-encode the artwork into a clean JPEG we created ourselves, exactly
        // like Dream Skin preset imports. Symlinks must resolve inside the pack.
        guard let sourceImage = theme.imageURL,
              sourceImage.resolvingSymlinksInPath().path.hasPrefix(packDir.path + "/"),
              let image = NSImage(contentsOf: sourceImage) else {
            throw ThemeError.missingImage(theme.id)
        }
        guard let bgData = ImageTools.normalizedWallpaperJPEG(image, maxSize: NSSize(width: 2560, height: 1440)) else {
            throw ThemeError.invalidPack
        }
        let dest = rootURL.appendingPathComponent(themeID, isDirectory: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try bgData.write(to: dest.appendingPathComponent("background.jpg"))
        if let thumb = ImageTools.thumbnailJPEG(image, size: NSSize(width: 480, height: 270)) {
            try thumb.write(to: dest.appendingPathComponent("thumb.jpg"))
        }
        theme.image = "background.jpg"
        try save(theme, to: dest)
        return try Theme.load(from: dest)
    }

    public func delete(_ theme: Theme) throws {
        guard !theme.isBundledPreset else { throw ThemeError.builtInTheme }
        guard let dir = theme.directory else { return }
        try fm.removeItem(at: dir)
    }

    public func save(_ theme: Theme, to dir: URL? = nil) throws {
        let target = dir ?? theme.directory ?? rootURL.appendingPathComponent(theme.id, isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(theme).write(to: target.appendingPathComponent("theme.json"))
    }

    // MARK: - Built-in gradient presets (generated, no binary assets)

    @discardableResult
    public func seedBuiltInPresets() -> Int {
        let presets: [(String, String, NSColor, NSColor)] = [
            ("preset-aura-aurora", "极光", NSColor(calibratedRed: 0.05, green: 0.35, blue: 0.45, alpha: 1),
             NSColor(calibratedRed: 0.35, green: 0.12, blue: 0.55, alpha: 1)),
            ("preset-aura-sunset", "落日", NSColor(calibratedRed: 0.55, green: 0.16, blue: 0.32, alpha: 1),
             NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.25, alpha: 1)),
            ("preset-aura-deepsea", "深海", NSColor(calibratedRed: 0.02, green: 0.10, blue: 0.25, alpha: 1),
             NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.60, alpha: 1)),
        ]
        var created = 0
        for (id, name, from, to) in presets {
            let dir = rootURL.appendingPathComponent(id, isDirectory: true)
            if fm.fileExists(atPath: dir.path) { continue }
            guard let image = ImageTools.gradientImage(size: NSSize(width: 2560, height: 1440), from: from, to: to),
                  let data = ImageTools.normalizedWallpaperJPEG(image, maxSize: NSSize(width: 2560, height: 1440)),
                  let thumb = ImageTools.thumbnailJPEG(image, size: NSSize(width: 480, height: 270))
            else { continue }
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: dir.appendingPathComponent("background.jpg"))
                try thumb.write(to: dir.appendingPathComponent("thumb.jpg"))
                let palette = PaletteExtractor.palette(for: image)
                let theme = Theme(
                    id: id, name: name, image: "background.jpg",
                    colors: Theme.Colors(
                        background: palette.background, panel: palette.panel, accent: palette.accent,
                        text: palette.text, muted: palette.muted, line: palette.line
                    )
                )
                try save(theme, to: dir)
                created += 1
            } catch { continue }
        }
        return created
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

enum ImageTools {
    /// Aspect-fill crop into `maxSize` (centered), JPEG q0.82.
    static func normalizedWallpaperJPEG(_ image: NSImage, maxSize: NSSize) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let srcW = CGFloat(cg.width), srcH = CGFloat(cg.height)
        let scale = max(maxSize.width / srcW, maxSize.height / srcH)
        let drawW = srcW * scale, drawH = srcH * scale
        let origin = NSPoint(x: (maxSize.width - drawW) / 2, y: (maxSize.height - drawH) / 2)
        return renderJPEG(size: maxSize) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(origin: origin, size: NSSize(width: drawW, height: drawH)),
                       from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    static func thumbnailJPEG(_ image: NSImage, size: NSSize) -> Data? {
        renderJPEG(size: size) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    static func gradientImage(size: NSSize, from: NSColor, to: NSColor) -> NSImage? {
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: from, ending: to)?.draw(in: NSRect(origin: .zero, size: size), angle: -35)
        image.unlockFocus()
        return image
    }

    private static func renderJPEG(size: NSSize, draw: (NSRect) -> Void) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}
