import UIKit

/// Rasterize once at the display's native scale; reuse the same glyphs while scrolling.
@MainActor
enum DanmakuTextRenderer {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    static func size(_ text: String, fontSize: Double, outline: Double) -> CGSize {
        let font = UIFont.systemFont(ofSize: min(60, max(12, fontSize)), weight: .regular)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let padding = ceil(min(3, max(0, outline))) + 1
        return CGSize(width: ceil(measured.width) + padding * 2,
                      height: ceil(measured.height) + padding * 2)
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
        let size = size(text, fontSize: fontSize, outline: outline)
        let padding = ceil(outline) + 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.setLineJoin(.round)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: UIColor(red: CGFloat((color >> 16) & 255) / 255,
                                          green: CGFloat((color >> 8) & 255) / 255,
                                          blue: CGFloat(color & 255) / 255, alpha: 1),
                .strokeColor: UIColor.black.withAlphaComponent(0.85),
                // UIKit expects a percentage of point size; negative means stroke AND fill.
                .strokeWidth: -outline / fontSize * 100
            ]
            (text as NSString).draw(at: CGPoint(x: padding, y: padding), withAttributes: attributes)
        }
        cache.setObject(image, forKey: key, cost: Int(size.width * size.height * scale * scale * 4))
        return image
    }
}
