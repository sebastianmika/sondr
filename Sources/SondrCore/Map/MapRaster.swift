import Foundation
import simd

/// Which part of the map is shown: the map point in the middle of the view and how many pixels one
/// map unit takes. Pixel y grows downwards, like the view.
public struct MapViewport: Equatable, Sendable {
    public static let minScale: Float = 1e-3
    public static let maxScale: Float = 1e5

    public var centre: SIMD2<Float>
    public var scale: Float

    public init(centre: SIMD2<Float>, scale: Float) {
        self.centre = centre
        self.scale = scale
    }

    public func toPixel(_ point: SIMD2<Float>, size: SIMD2<Float>) -> SIMD2<Float> {
        size / 2 + (point - centre) * scale
    }

    public func toMap(_ pixel: SIMD2<Float>, size: SIMD2<Float>) -> SIMD2<Float> {
        centre + (pixel - size / 2) / scale
    }

    /// Shows (nearly) all points: the central 99 % in each direction, with a margin, so a few far
    /// outliers do not squash the rest. Both axes use the same scale.
    public static func fitting(x: [Float], y: [Float], size: SIMD2<Float>) -> MapViewport {
        guard !x.isEmpty, x.count == y.count else { return MapViewport(centre: .zero, scale: 1) }
        func bounds(_ values: [Float]) -> (Float, Float) {
            let sorted = values.sorted()
            let n = sorted.count - 1
            return (sorted[Int((0.005 * Double(n)).rounded(.down))], sorted[Int((0.995 * Double(n)).rounded(.up))])
        }
        let (x0, x1) = bounds(x), (y0, y1) = bounds(y)
        let width = max(x1 - x0, 1e-6), height = max(y1 - y0, 1e-6)
        let scale = min(size.x / (width * 1.1), size.y / (height * 1.1))
        return MapViewport(
            centre: SIMD2((x0 + x1) / 2, (y0 + y1) / 2),
            scale: x1 - x0 < 1e-6 && y1 - y0 < 1e-6 ? 1 : min(max(scale, minScale), maxScale))
    }

    /// Zooms by `factor`, keeping the map point under `pixel` where it is.
    public func zoomed(by factor: Float, around pixel: SIMD2<Float>, size: SIMD2<Float>) -> MapViewport {
        let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
        let anchor = toMap(pixel, size: size)
        return MapViewport(centre: anchor - (pixel - size / 2) / newScale, scale: newScale)
    }

    /// Moves the map by `delta` pixels, as if dragged.
    public func panned(by delta: SIMD2<Float>) -> MapViewport {
        MapViewport(centre: centre - delta / scale, scale: scale)
    }
}

/// Draws the map into a bitmap. Dots are tiny squares composited over each other, so 250k of them
/// take a few milliseconds and the view only has to show one image.
public enum MapRaster {
    private static let normalAlpha: UInt32 = 217
    private static let fadedAlpha: UInt32 = 36
    private static let highlightedAlpha: UInt32 = 240

    /// A dot size that suits how crowded the map is, in pixels.
    public static func defaultRadius(count: Int, width: Int, height: Int) -> Float {
        guard count > 0 else { return 3.5 }
        return min(max(0.4 * (Float(width * height) / Float(count)).squareRoot(), 1), 3.5)
    }

    /// - Parameters:
    ///   - highlight: If set, only these samples are drawn at full strength; the rest fades.
    ///   - radius: Dot size in pixels; nil picks one from the number of dots.
    /// - Returns: `width * height * 4` bytes, RGBA, premultiplied alpha, row 0 at the top.
    public static func render(
        _ dots: MapDots, viewport: MapViewport, width: Int, height: Int, highlight: Set<Int64>?, radius: Float?
    ) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: max(width, 0) * max(height, 0) * 4)
        guard width > 0, height > 0, dots.count > 0 else { return buffer }
        let size = SIMD2(Float(width), Float(height))
        let half = max(0, Int(((radius ?? defaultRadius(count: dots.count, width: width, height: height)) - 0.5).rounded(.down)))
        let colours = (0...8).map { ClusterPalette.rgb(forCluster: $0 - 1) }
        let origin = size / 2 - viewport.centre * viewport.scale

        buffer.withUnsafeMutableBufferPointer { pixels in
            func paint(_ index: Int, alpha: UInt32) {
                let px = Int((origin.x + dots.x[index] * viewport.scale).rounded(.down))
                let py = Int((origin.y + dots.y[index] * viewport.scale).rounded(.down))
                guard px + half >= 0, px - half < width, py + half >= 0, py - half < height else { return }
                let colour = colours[min(max(dots.cluster[index] + 1, 0), colours.count - 1)]
                let r = UInt32(colour.red) * alpha / 255, g = UInt32(colour.green) * alpha / 255, b = UInt32(colour.blue) * alpha / 255
                let keep = 255 - alpha
                for y in max(py - half, 0)...min(py + half, height - 1) {
                    for x in max(px - half, 0)...min(px + half, width - 1) {
                        let o = (y * width + x) * 4
                        pixels[o] = UInt8(r + UInt32(pixels[o]) * keep / 255)
                        pixels[o + 1] = UInt8(g + UInt32(pixels[o + 1]) * keep / 255)
                        pixels[o + 2] = UInt8(b + UInt32(pixels[o + 2]) * keep / 255)
                        pixels[o + 3] = UInt8(alpha + UInt32(pixels[o + 3]) * keep / 255)
                    }
                }
            }
            if let highlight {
                for i in 0..<dots.count where !highlight.contains(dots.ids[i]) { paint(i, alpha: fadedAlpha) }
                for i in 0..<dots.count where highlight.contains(dots.ids[i]) { paint(i, alpha: highlightedAlpha) }
            } else {
                for i in 0..<dots.count { paint(i, alpha: normalAlpha) }
            }
        }
        return buffer
    }

    /// Index of the dot nearest to `pixel` and within `maxDistance` pixels of it.
    public static func nearest(
        in dots: MapDots, to pixel: SIMD2<Float>, viewport: MapViewport, size: SIMD2<Float>, maxDistance: Float
    ) -> Int? {
        let target = viewport.toMap(pixel, size: size)
        let reach = (maxDistance / viewport.scale) * (maxDistance / viewport.scale)
        var best: (index: Int, distance: Float)?
        for i in 0..<dots.count {
            let dx = dots.x[i] - target.x, dy = dots.y[i] - target.y
            let d = dx * dx + dy * dy
            if d <= reach, d < (best?.distance ?? .infinity) { best = (i, d) }
        }
        return best?.index
    }

    /// Indices of the dots inside a pixel rectangle (given by any two opposite corners), ascending.
    public static func indices(
        in dots: MapDots, rect: (min: SIMD2<Float>, max: SIMD2<Float>), viewport: MapViewport, size: SIMD2<Float>
    ) -> [Int] {
        let a = viewport.toMap(simd_min(rect.min, rect.max), size: size), b = viewport.toMap(simd_max(rect.min, rect.max), size: size)
        return (0..<dots.count).filter { dots.x[$0] >= a.x && dots.x[$0] <= b.x && dots.y[$0] >= a.y && dots.y[$0] <= b.y }
    }
}
