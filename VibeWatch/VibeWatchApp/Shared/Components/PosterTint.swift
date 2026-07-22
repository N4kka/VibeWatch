import SwiftUI
import CoreImage

/// Computes and caches a subtle ambient tint sampled from a poster's average color.
///
/// List cards use this to give each row a faint per-poster wash at the poster edge — the
/// "signature" of the Lists redesign — replacing the old uniform tinted card background.
/// The raw average of a poster is usually muddy and desaturated, so we push saturation up
/// and clamp brightness into a usable range. Results are memoized by image URL because the
/// same poster scrolls in and out of view many times.
enum PosterTint {
    private static let context = CIContext(options: [.workingColorSpace: NSNull()])
    private static var cache: [String: Color] = [:]
    private static let lock = NSLock()

    /// Returns a previously computed tint if available, without touching CoreImage.
    static func cached(for key: String) -> Color? {
        lock.lock(); defer { lock.unlock() }
        return cache[key]
    }

    /// Computes (or returns the cached) ambient tint for `image`, keyed by `key` (the poster URL).
    static func compute(from image: UIImage, key: String) -> Color {
        if let hit = cached(for: key) { return hit }
        let tint = averageColor(image).map { Color($0.boostedTint()) } ?? .clear
        lock.lock(); cache[key] = tint; lock.unlock()
        return tint
    }

    private static func averageColor(_ image: UIImage) -> UIColor? {
        guard let input = CIImage(image: image) else { return nil }
        let extent = input.extent
        let vector = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.width, w: extent.height)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: input, kCIInputExtentKey: vector]),
              let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(output,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())

        return UIColor(red: CGFloat(bitmap[0]) / 255,
                       green: CGFloat(bitmap[1]) / 255,
                       blue: CGFloat(bitmap[2]) / 255,
                       alpha: 1)
    }
}

private extension UIColor {
    /// Push a muddy average toward a usable accent wash: boost saturation, clamp brightness.
    func boostedTint() -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h,
                       saturation: min(max(s * 1.5, 0.35), 0.7),
                       brightness: min(max(b, 0.45), 0.78),
                       alpha: 1)
    }
}
