import XCTest
import AppKit
import CodexAuraCore

final class ThemeDecodingTests: XCTestCase {
    func testLegacyThemeDefaultsToAutomaticAppearanceAndFirstRevision() throws {
        let json = #"""
        {
          "id": "legacy-theme",
          "name": "Legacy",
          "image": "background.jpg",
          "colors": {
            "background": "#101216",
            "panel": "#171a20",
            "accent": "#7aa2f7",
            "text": "#eceef2",
            "muted": "#a2a8b0",
            "line": "rgba(255,255,255,.14)"
          }
        }
        """#

        let theme = try JSONDecoder().decode(Theme.self, from: Data(json.utf8))

        XCTAssertEqual(theme.appearance, .auto)
        XCTAssertEqual(theme.revision, 1)
        XCTAssertEqual(theme.contentMask, 1)
        XCTAssertNil(theme.colors.onAccent)
    }

    static let allTests = [
        (
            "testLegacyThemeDefaultsToAutomaticAppearanceAndFirstRevision",
            testLegacyThemeDefaultsToAutomaticAppearanceAndFirstRevision
        )
    ]
}

final class ThemePresentationTests: XCTestCase {
    func testLightAppearanceUsesLightControlsAndWhiteReadabilityScrim() {
        let theme = Theme(
            id: "light",
            name: "Light",
            image: "background.jpg",
            appearance: .light,
            colors: Theme.Colors(
                background: "#e8f2fc",
                panel: "#ffffff",
                accent: "#2b7cd3",
                text: "#1d3a5f",
                muted: "#607b98",
                line: "rgba(43,124,211,.22)"
            )
        )

        let presentation = ThemePresentation.resolve(theme)

        XCTAssertEqual(presentation.colorScheme, "light")
        XCTAssertEqual(presentation.scrimRGB, "255 255 255")
        XCTAssertEqual(presentation.onAccent, "#000000")
    }

    func testAutomaticAppearanceAndExplicitAccentForeground() {
        let darkTheme = Theme(
            id: "automatic-dark",
            name: "Automatic dark",
            image: "background.jpg",
            colors: Theme.Colors(
                background: "#101216",
                panel: "#171a20",
                accent: "#202020",
                text: "#eceef2",
                muted: "#a2a8b0",
                line: "rgba(255,255,255,.14)"
            )
        )
        let lightTheme = Theme(
            id: "automatic-light",
            name: "Automatic light",
            image: "background.jpg",
            colors: Theme.Colors(
                background: "#f6f1e7",
                panel: "#ffffff",
                accent: "#f2cf65",
                text: "#263238",
                muted: "#607d8b",
                line: "rgba(38,50,56,.18)",
                onAccent: "#123456"
            )
        )

        XCTAssertEqual(ThemePresentation.resolve(darkTheme).colorScheme, "dark")
        XCTAssertEqual(ThemePresentation.resolve(darkTheme).scrimRGB, "0 0 0")
        XCTAssertEqual(ThemePresentation.resolve(darkTheme).onAccent, "#ffffff")
        XCTAssertEqual(ThemePresentation.resolve(lightTheme).colorScheme, "light")
        XCTAssertEqual(ThemePresentation.resolve(lightTheme).onAccent, "#123456")
    }

    static let allTests = [
        (
            "testLightAppearanceUsesLightControlsAndWhiteReadabilityScrim",
            testLightAppearanceUsesLightControlsAndWhiteReadabilityScrim
        ),
        (
            "testAutomaticAppearanceAndExplicitAccentForeground",
            testAutomaticAppearanceAndExplicitAccentForeground
        )
    ]
}

final class BundledPresetCatalogTests: XCTestCase {
    func testInstallAddsValidPresetAndIsIdempotent() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAuraTests-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("Bundled", isDirectory: true)
        let destination = temp.appendingPathComponent("Installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try writePreset(id: "preset-test", revision: 2, to: source)
        let catalog = BundledPresetCatalog(sourceRoot: source)
        let library = ThemeLibrary(rootURL: destination)

        let first = try catalog.install(into: library)
        let second = try catalog.install(into: library)

        XCTAssertEqual(first, .init(installed: 1, updated: 0, unchanged: 0))
        XCTAssertEqual(second, .init(installed: 0, updated: 0, unchanged: 1))
        XCTAssertEqual(try Theme.load(from: destination.appendingPathComponent("preset-test")).revision, 2)
    }

    func testUpgradeReplacesPresetContentButPreservesUserTuning() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAuraTests-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("Bundled", isDirectory: true)
        let destination = temp.appendingPathComponent("Installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try writePreset(id: "preset-test", revision: 1, to: source)
        let catalog = BundledPresetCatalog(sourceRoot: source)
        let library = ThemeLibrary(rootURL: destination)
        _ = try catalog.install(into: library)
        var tuned = try XCTUnwrap(library.listThemes().first)
        tuned.dim = 0.62
        tuned.blur = 7
        tuned.contentMask = 0.35
        try library.save(tuned)

        try writePreset(id: "preset-test", revision: 2, to: source)
        let report = try catalog.install(into: library)
        let upgraded = try Theme.load(from: destination.appendingPathComponent("preset-test"))
        let art = try Data(contentsOf: destination.appendingPathComponent("preset-test/background.jpg"))

        XCTAssertEqual(report, .init(installed: 0, updated: 1, unchanged: 0))
        XCTAssertEqual(upgraded.revision, 2)
        XCTAssertEqual(upgraded.dim, 0.62)
        XCTAssertEqual(upgraded.blur, 7)
        XCTAssertEqual(upgraded.contentMask, 0.35)
        XCTAssertEqual(art, Data("background-v2".utf8))
    }

    func testDeleteProtectsInstalledPresetButAllowsCustomTheme() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAuraTests-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("Bundled", isDirectory: true)
        let destination = temp.appendingPathComponent("Installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try writePreset(id: "preset-test", revision: 1, to: source)
        let library = ThemeLibrary(rootURL: destination)
        _ = try BundledPresetCatalog(sourceRoot: source).install(into: library)
        let installed = try XCTUnwrap(library.listThemes().first)

        XCTAssertThrowsError(try library.delete(installed)) { error in
            guard case ThemeError.builtInTheme = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("preset-test").path
        ))

        try writePreset(id: "custom-test", revision: 1, to: destination)
        let custom = try Theme.load(from: destination.appendingPathComponent("custom-test"))
        try library.delete(custom)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("custom-test").path
        ))
    }

    func testInstallClaimsReservedIDWhenExistingThemeIsNotBundled() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAuraTests-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("Bundled", isDirectory: true)
        let destination = temp.appendingPathComponent("Installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try writePreset(id: "preset-test", revision: 1, to: source)
        try writePreset(id: "preset-test", revision: 1, to: destination)
        let library = ThemeLibrary(rootURL: destination)

        let report = try BundledPresetCatalog(sourceRoot: source).install(into: library)
        let installed = try Theme.load(from: destination.appendingPathComponent("preset-test"))

        XCTAssertEqual(report, .init(installed: 0, updated: 1, unchanged: 0))
        XCTAssertTrue(installed.isBundledPreset)
    }

    func testInstallRemovesRetiredBundledPresetButPreservesUnmarkedTheme() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAuraTests-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("Bundled", isDirectory: true)
        let destination = temp.appendingPathComponent("Installed", isDirectory: true)
        let retiredIDs = [
            "preset-millennium-messenger",
            "preset-fortune-dev",
            "preset-starlight-captain",
        ]
        defer { try? FileManager.default.removeItem(at: temp) }

        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for id in retiredIDs {
            try writePreset(id: id, revision: 1, to: destination)
            try Data().write(to: destination.appendingPathComponent(id, isDirectory: true)
                .appendingPathComponent(".codexaura-bundled"))
        }

        let catalog = BundledPresetCatalog(sourceRoot: source)
        _ = try catalog.install(into: ThemeLibrary(rootURL: destination))
        for id in retiredIDs {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: destination.appendingPathComponent(id, isDirectory: true).path
            ))
        }

        let unmarkedID = "preset-fortune-dev"
        try writePreset(id: unmarkedID, revision: 1, to: destination)
        _ = try catalog.install(into: ThemeLibrary(rootURL: destination))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(unmarkedID, isDirectory: true).path
        ))
    }

    func testPromotesMatchingLegacyPrototypeAndPreservesTuning() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAuraTests-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("Bundled", isDirectory: true)
        let destination = temp.appendingPathComponent("Installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try writePreset(id: "preset-blue-muse", revision: 1, to: source)
        try writePreset(id: "custom-1784285547", revision: 1, to: destination)
        let library = ThemeLibrary(rootURL: destination)
        var legacy = try Theme.load(from: destination.appendingPathComponent("custom-1784285547"))
        legacy.dim = 0.54
        legacy.blur = 3
        legacy.contentMask = 0.4
        try library.save(legacy)

        _ = try BundledPresetCatalog(sourceRoot: source).install(into: library)

        let promoted = try Theme.load(from: destination.appendingPathComponent("preset-blue-muse"))
        XCTAssertEqual(promoted.dim, 0.54)
        XCTAssertEqual(promoted.blur, 3)
        XCTAssertEqual(promoted.contentMask, 0.4)
        XCTAssertTrue(promoted.isBundledPreset)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("custom-1784285547").path
        ))
    }

    func testPreservesLegacyPrototypeWhenArtworkDoesNotMatch() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAuraTests-\(UUID().uuidString)", isDirectory: true)
        let source = temp.appendingPathComponent("Bundled", isDirectory: true)
        let destination = temp.appendingPathComponent("Installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        try writePreset(id: "preset-blue-muse", revision: 1, to: source)
        try writePreset(id: "custom-1784285547", revision: 2, to: destination)

        _ = try BundledPresetCatalog(sourceRoot: source).install(
            into: ThemeLibrary(rootURL: destination)
        )

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("custom-1784285547").path
        ))
    }

    func testBundledResourcesContainEightValidOptimizedThemePacks() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexAuraTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let library = ThemeLibrary(rootURL: destination)

        let report = try BundledPresetCatalog().install(into: library)
        let themes = library.listThemes()

        XCTAssertEqual(report.installed, 8)
        XCTAssertEqual(Set(themes.map(\.id)), [
            "preset-amber-dusk",
            "preset-blue-muse",
            "preset-cyber-neon",
            "preset-forest-mist",
            "preset-midnight-aurora",
            "preset-paper-cut-guardian",
            "preset-happy-kitchen",
            "preset-sakura-dawn",
        ])
        XCTAssertEqual(Set(themes.map(\.name)), [
            "葫芦娃", "元气食堂", "蓝调缪斯", "琥珀黄昏",
            "赛博霓虹", "森野薄雾", "午夜极光", "樱粉晨曦",
        ])
        for theme in themes {
            let imageURL = try XCTUnwrap(theme.imageURL)
            let thumbnailURL = try XCTUnwrap(theme.thumbnailURL)
            let image = try XCTUnwrap(NSImage(contentsOf: imageURL)?.cgImage(
                forProposedRect: nil, context: nil, hints: nil
            ))
            let thumbnail = try XCTUnwrap(NSImage(contentsOf: thumbnailURL)?.cgImage(
                forProposedRect: nil, context: nil, hints: nil
            ))
            let bytes = try XCTUnwrap(
                try imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            )

            XCTAssertEqual([image.width, image.height], [2560, 1440], theme.id)
            XCTAssertEqual([thumbnail.width, thumbnail.height], [480, 270], theme.id)
            XCTAssertLessThan(bytes, 1_500_000, theme.id)
            XCTAssertTrue(theme.isBundledPreset, theme.id)
        }
    }

    private func writePreset(id: String, revision: Int, to root: URL) throws {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let theme = Theme(
            revision: revision,
            id: id,
            name: "Test preset",
            image: "background.jpg",
            colors: Theme.Colors(
                background: "#101216", panel: "#171a20", accent: "#7aa2f7",
                text: "#eceef2", muted: "#a2a8b0", line: "rgba(255,255,255,.14)"
            )
        )
        let encoder = JSONEncoder()
        try encoder.encode(theme).write(to: directory.appendingPathComponent("theme.json"))
        try Data("background-v\(revision)".utf8).write(to: directory.appendingPathComponent("background.jpg"))
        try Data("thumb-v\(revision)".utf8).write(to: directory.appendingPathComponent("thumb.jpg"))
    }

    static let allTests = [
        ("testInstallAddsValidPresetAndIsIdempotent", testInstallAddsValidPresetAndIsIdempotent),
        ("testUpgradeReplacesPresetContentButPreservesUserTuning", testUpgradeReplacesPresetContentButPreservesUserTuning),
        ("testDeleteProtectsInstalledPresetButAllowsCustomTheme", testDeleteProtectsInstalledPresetButAllowsCustomTheme),
        ("testInstallClaimsReservedIDWhenExistingThemeIsNotBundled", testInstallClaimsReservedIDWhenExistingThemeIsNotBundled),
        ("testInstallRemovesRetiredBundledPresetButPreservesUnmarkedTheme", testInstallRemovesRetiredBundledPresetButPreservesUnmarkedTheme),
        ("testPromotesMatchingLegacyPrototypeAndPreservesTuning", testPromotesMatchingLegacyPrototypeAndPreservesTuning),
        ("testPreservesLegacyPrototypeWhenArtworkDoesNotMatch", testPreservesLegacyPrototypeWhenArtworkDoesNotMatch),
        ("testBundledResourcesContainEightValidOptimizedThemePacks", testBundledResourcesContainEightValidOptimizedThemePacks)
    ]
}

final class RendererStyleTests: XCTestCase {
    func testContentMaskControlsMainAndSidebarOverlays() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cssURL = repositoryRoot.appendingPathComponent("Sources/CodexAura/Renderer/skin.css")
        let css = try String(contentsOf: cssURL, encoding: .utf8)

        XCTAssertTrue(css.contains("opacity: var(--aura-content-mask, 1);"))
        XCTAssertTrue(css.contains(
            "background: rgb(var(--aura-bg-rgb) / calc(0.42 * var(--aura-content-mask, 1))) !important;"
        ))
        XCTAssertTrue(css.contains(
            "background: rgb(var(--aura-panel-rgb) / calc(0.68 * var(--aura-content-mask, 1))) !important;"
        ))
    }

    func testHomeSuggestionGroupUsesNativeVerticalPositionAndCentersContents() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cssURL = repositoryRoot.appendingPathComponent("Sources/CodexAura/Renderer/skin.css")
        let css = try String(contentsOf: cssURL, encoding: .utf8)

        XCTAssertFalse(css.contains("transform: translateY(48px);"))
        XCTAssertTrue(css.contains("justify-content: center !important;"))
        XCTAssertTrue(css.contains("flex: 0 1 auto !important;"))
    }

    static let allTests = [
        ("testContentMaskControlsMainAndSidebarOverlays", testContentMaskControlsMainAndSidebarOverlays),
        (
            "testHomeSuggestionGroupUsesNativeVerticalPositionAndCentersContents",
            testHomeSuggestionGroupUsesNativeVerticalPositionAndCentersContents
        )
    ]
}

XCTMain([
    testCase(ThemeDecodingTests.allTests),
    testCase(ThemePresentationTests.allTests),
    testCase(BundledPresetCatalogTests.allTests),
    testCase(RendererStyleTests.allTests)
])
