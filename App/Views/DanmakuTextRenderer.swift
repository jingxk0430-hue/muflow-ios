import CoreText
import UIKit

/// Rasterize once at the display's native scale; reuse the same glyphs while scrolling.
@MainActor
enum DanmakuTextRenderer {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    private static func layout(_ text: String, fontSize: Double) -> (CTLine, CGRect) {
        let system = UIFont.systemFont(ofSize: min(60, max(12, fontSize)), weight: .regular)
        let font = CTFontCreateWithName(system.fontName as CFString, system.pointSize, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let metrics = CGRect(x: 0, y: -descent, width: width, height: ascent + descent + leading)
        return (line, CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).union(metrics).integral)
    }

    static func size(_ text: String, fontSize: Double, outline: Double) -> CGSize {
        let (_, bounds) = layout(text, fontSize: fontSize)
        let padding = ceil(min(3, max(0, outline))) + 2
        return CGSize(width: max(1, bounds.width) + padding * 2,
                      height: max(1, bounds.height) + padding * 2)
    }

    static func image(_ text: String, color: UInt32 = 0xFFFFFF, fontSize: Double,
                      outline: Double, scale: CGFloat) -> UIImage {
        let fontSize = min(60, max(12, fontSize))
        let outline = min(3, max(0, outline))
        let key = "\(fontSize)|\(outline)|\(scale)|\(color)|\(text)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        let (line, bounds) = layout(text, fontSize: fontSize)
        let padding = ceil(outline) + 2
        let size = CGSize(width: max(1, bounds.width) + padding * 2,
                          height: max(1, bounds.height) + padding * 2)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            context.translateBy(x: padding - bounds.minX, y: padding + bounds.maxY)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            context.setLineJoin(.round)
            let paths = CGMutablePath()
            var bitmapRuns: [CTRun] = []
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let font = attributes[kCTFontAttributeName] as! CTFont
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                // Color emoji require Core Text's bitmap rendering. Spaces simply have no path.
                if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) {
                    bitmapRuns.append(run)
                    continue
                }
                for index in glyphs.indices {
                    guard let path = CTFontCreatePathForGlyph(font, glyphs[index], nil) else { continue }
                    let transform = CGAffineTransform(translationX: positions[index].x, y: positions[index].y)
                    paths.addPath(path, transform: transform)
                }
            }
            if outline > 0 {
                context.addPath(paths)
                context.setStrokeColor(UIColor.black.withAlphaComponent(0.85).cgColor)
                context.setLineWidth(outline * 2)
                context.strokePath()
            }
            context.addPath(paths)
            context.setFillColor(UIColor(red: CGFloat((color >> 16) & 255) / 255,
                                         green: CGFloat((color >> 8) & 255) / 255,
                                         blue: CGFloat(color & 255) / 255, alpha: 1).cgColor)
            context.fillPath()
            for run in bitmapRuns {
                context.textPosition = .zero
                CTRunDraw(run, context, CFRange(location: 0, length: 0))
            }
        }
        cache.setObject(image, forKey: key, cost: Int(size.width * size.height * scale * scale * 4))
        return image
    }
}
