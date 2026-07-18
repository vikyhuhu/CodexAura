import Foundation
import AppKit

struct Palette {
    let background: String
    let panel: String
    let accent: String
    let text: String
    let muted: String
    let line: String

    static let fallback = Palette(
        background: "#101216", panel: "#171a20", accent: "#7aa2f7",
        text: "#eceef2", muted: "#a2a8b0", line: "rgba(255,255,255,.14)"
    )
}

enum PaletteExtractor {
    /// Extract a readable dark palette from an image: average color drives the
    /// panels, the most saturated mid-brightness sample becomes the accent.
    static func palette(for image: NSImage) -> Palette {
        guard let samples = downsampledPixels(image, size: 48) else { return .fallback }
        var total = (r: 0.0, g: 0.0, b: 0.0)
        var best: (score: Double, h: Double) = (0, 0)
        for pixel in samples {
            total.r += pixel.r; total.g += pixel.g; total.b += pixel.b
            let hsl = rgbToHsl(pixel)
            // Prefer saturated colors that are neither too dark nor washed out.
            let score = hsl.s * (1 - abs(hsl.l - 0.55) * 1.6)
            if score > best.score { best = (score, hsl.h) }
        }
        let count = Double(samples.count)
        let avg = RGB(r: total.r / count, g: total.g / count, b: total.b / count)
        let avgHsl = rgbToHsl(avg)

        let background = hslString(h: avgHsl.h, s: min(avgHsl.s, 0.35), l: 0.10)
        let panel = hslString(h: avgHsl.h, s: min(avgHsl.s, 0.32), l: 0.16)
        let accent = hslString(h: best.score > 0.08 ? best.h : avgHsl.h, s: 0.72, l: 0.62)
        return Palette(
            background: background,
            panel: panel,
            accent: accent,
            text: "#eceef2",
            muted: "#a2a8b0",
            line: "rgba(255,255,255,.14)"
        )
    }

    // MARK: - Pixel math

    private struct RGB { var r: Double; var g: Double; var b: Double }

    private static func downsampledPixels(_ image: NSImage, size: Int) -> [RGB]? {
        let width = size, height = size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        let bytesPerRow = rep.bytesPerRow
        var pixels: [RGB] = []
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixels.append(RGB(
                    r: Double(data[offset]) / 255,
                    g: Double(data[offset + 1]) / 255,
                    b: Double(data[offset + 2]) / 255
                ))
            }
        }
        return pixels
    }

    private static func rgbToHsl(_ c: RGB) -> (h: Double, s: Double, l: Double) {
        let maxC = max(c.r, c.g, c.b), minC = min(c.r, c.g, c.b)
        let l = (maxC + minC) / 2
        if maxC == minC { return (0, 0, l) }
        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        let h: Double
        if maxC == c.r { h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0) }
        else if maxC == c.g { h = (c.b - c.r) / d + 2 }
        else { h = (c.r - c.g) / d + 4 }
        return (h * 60, s, l)
    }

    private static func hslString(h: Double, s: Double, l: Double) -> String {
        let hue = ((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let channel: (Double) -> Double = { t0 in
            var t = t0
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let r = Int((channel(hue + 1.0 / 3) * 255).rounded())
        let g = Int((channel(hue) * 255).rounded())
        let b = Int((channel(hue - 1.0 / 3) * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
