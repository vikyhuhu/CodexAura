import Foundation

/// Installs the read-only preset catalog from the app bundle into the writable
/// theme library. Resource discovery, validation and idempotency stay behind
/// this single interface.
public struct BundledPresetCatalog {
    public struct InstallReport: Equatable {
        public let installed: Int
        public let updated: Int
        public let unchanged: Int

        public init(installed: Int, updated: Int, unchanged: Int) {
            self.installed = installed
            self.updated = updated
            self.unchanged = unchanged
        }
    }

    private let sourceRoot: URL
    private let fm: FileManager

    public init(sourceRoot: URL? = nil, fileManager: FileManager = .default) {
        self.sourceRoot = sourceRoot
            ?? Bundle.module.url(forResource: "Presets", withExtension: nil)!
        fm = fileManager
    }

    public func install(into library: ThemeLibrary) throws -> InstallReport {
        try fm.createDirectory(at: library.rootURL, withIntermediateDirectories: true)
        let entries = try fm.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var installed = 0
        var updated = 0
        var unchanged = 0

        for source in entries {
            let theme = try Theme.load(from: source)
            guard Self.isValidID(theme.id), source.lastPathComponent == theme.id else {
                throw ThemeError.invalidPack
            }
            let destination = library.rootURL.appendingPathComponent(theme.id, isDirectory: true)
            let existing = try? Theme.load(from: destination)
            // Catalog IDs are reserved. A same-ID theme without our marker may
            // be an older manual import, so replace it with the canonical pack
            // instead of mistaking it for an installed bundled preset.
            if let existing, existing.isBundledPreset, existing.revision >= theme.revision {
                unchanged += 1
                continue
            }

            let existed = fm.fileExists(atPath: destination.path)
            let staging = library.rootURL.appendingPathComponent(
                ".install-\(theme.id)-\(UUID().uuidString)", isDirectory: true
            )
            defer { try? fm.removeItem(at: staging) }
            try fm.copyItem(at: source, to: staging)
            try Data().write(to: staging.appendingPathComponent(Theme.bundledMarkerName))
            if let existing {
                var replacement = try Theme.load(from: staging)
                replacement.dim = existing.dim
                replacement.blur = existing.blur
                try library.save(replacement, to: staging)
            }
            if existed { try fm.removeItem(at: destination) }
            try fm.moveItem(at: staging, to: destination)
            if existed { updated += 1 } else { installed += 1 }
        }

        return InstallReport(installed: installed, updated: updated, unchanged: unchanged)
    }

    private static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$"#, options: .regularExpression) != nil
            && !id.contains("..")
    }
}
