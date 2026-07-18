import Foundation

enum PayloadBuilder {
    private static let maxArtBytes = 16 * 1024 * 1024

    static func rendererSource(named name: String) throws -> String {
        // Bundle.module covers the packaged .app; fall back to sources next to
        // the executable for bare `swift build` runs.
        if let url = Bundle.module.url(forResource: name, withExtension: nil),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        let fallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Renderer/\(name)")
        return try String(contentsOf: fallback, encoding: .utf8)
    }

    private static func jsonLiteral(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    /// Theme colors land in CSS verbatim. Reject anything that could smuggle a
    /// network fetch (url(...)) or break string context, so an untrusted pack
    /// stays a passive palette instead of a beacon.
    private static func sanitizedColor(_ value: String) throws -> String {
        guard !value.lowercased().contains("url"),
              !value.contains("\""), !value.contains("\\"),
              !value.contains("\n"), !value.contains("\r")
        else { throw ThemeError.invalidPack }
        return value
    }

    /// Build the complete injection script for a theme.
    static func buildPayload(for theme: Theme) throws -> String {
        guard let imageURL = theme.imageURL else { throw ThemeError.missingImage(theme.id) }
        let data = try Data(contentsOf: imageURL)
        guard !data.isEmpty, data.count <= maxArtBytes else { throw ThemeError.imageTooLarge }
        let ext = imageURL.pathExtension.lowercased()
        let mime = (ext == "jpg" || ext == "jpeg") ? "image/jpeg" : ext == "webp" ? "image/webp" : "image/png"
        let artDataURL = "data:\(mime);base64,\(data.base64EncodedString())"

        let template = try rendererSource(named: "payload.js")
        let css = try rendererSource(named: "skin.css")
        let themeDict: [String: Any] = [
            "id": theme.id,
            "name": theme.name,
            "dim": theme.dim,
            "blur": theme.blur,
            "focusX": theme.focusX,
            "focusY": theme.focusY,
            "bordered": AuraSettings.load().bordered,
            "tagline": AuraSettings.load().tagline,
            "colors": [
                "background": try sanitizedColor(theme.colors.background),
                "panel": try sanitizedColor(theme.colors.panel),
                "accent": try sanitizedColor(theme.colors.accent),
                "text": try sanitizedColor(theme.colors.text),
                "muted": try sanitizedColor(theme.colors.muted),
                "line": try sanitizedColor(theme.colors.line),
            ],
        ]
        return template
            .replacingOccurrences(of: "__AURA_CSS_JSON__", with: try jsonLiteral(css))
            .replacingOccurrences(of: "__AURA_ART_JSON__", with: try jsonLiteral(artDataURL))
            .replacingOccurrences(of: "__AURA_THEME_JSON__", with: try jsonLiteral(themeDict))
    }

    /// Removes every trace of the skin from the page.
    static let cleanupScript = #"""
    (() => {
      try {
        // Kill-switch: orphan early-scripts from previous app runs (which a new
        // process cannot unregister) check this flag and no-op themselves.
        localStorage.setItem('codexaura:disabled', '1');
        localStorage.removeItem('codexaura:tweaks');
      } catch (e) {}
      const state = window.__CODEX_AURA_STATE__;
      if (state?.cleanup) return state.cleanup();
      document.documentElement?.classList.remove('codex-aura');
      document.documentElement?.classList.remove('aura-bordered');
      document.getElementById('codex-aura-style')?.remove();
      delete window.__CODEX_AURA_STATE__;
      return true;
    })()
    """#

    /// Clears the kill-switch right before (re)applying a theme.
    static let unlockScript = #"(() => { try { localStorage.removeItem('codexaura:disabled'); } catch (e) {} return true; })()"#

    /// Confirms the page is the Codex shell before we touch it.
    static let probeScript = #"""
    (() => {
      const shell = Boolean(document.querySelector('main.main-surface'));
      const sidebar = Boolean(document.querySelector('aside.app-shell-left-panel'));
      return { codex: shell && sidebar, shell, sidebar, title: document.title, href: location.href };
    })()
    """#

    /// Post-injection sanity check.
    static let verifyScript = #"""
    (() => ({
      installed: document.documentElement.classList.contains('codex-aura'),
      stylePresent: Boolean(document.getElementById('codex-aura-style')),
      themeId: window.__CODEX_AURA_STATE__?.themeId ?? null,
      overflowX: document.documentElement.scrollWidth > document.documentElement.clientWidth,
      sidebarVisible: (() => { const n = document.querySelector('aside.app-shell-left-panel'); if (!n) return false; const r = n.getBoundingClientRect(); return r.width > 0 && r.height > 0; })(),
    }))()
    """#
}
