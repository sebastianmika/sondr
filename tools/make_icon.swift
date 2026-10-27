// Draws the Sondr app icon ("Signal Grid", see docs/DESIGN.md) into App/Assets.xcassets/AppIcon.appiconset.
// Usage: swift tools/make_icon.swift [output-dir]     (make icon)
// A 5x5 field of step keys, thirteen lit orange ones tracing an S, on a graphite tile (Big Sur grid: 824 of 1024 px).
// At 32 px and below the 5x5 field cannot be resolved, so a 3x5 pixel S is drawn instead.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = CommandLine.arguments.dropFirst().first ?? "App/Assets.xcassets/AppIcon.appiconset"

/// Lit keys of the 5x5 field as (row, column).
let lit: Set<[Int]> = [[0, 1], [0, 2], [0, 3], [0, 4], [1, 0], [2, 1], [2, 2], [2, 3], [3, 4], [4, 0], [4, 1], [4, 2], [4, 3]]
/// The 3x5 pixel S of the small sizes, as (row, column).
let pixelS: Set<[Int]> = [[0, 0], [0, 1], [0, 2], [1, 0], [2, 0], [2, 1], [2, 2], [3, 2], [4, 0], [4, 1], [4, 2]]

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: srgb,
        components: [CGFloat(hex >> 16) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha])!
}

func render(pixels size: Int) -> CGImage {
    let s = CGFloat(size)
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work top-left, 1024-unit design space.
    context.translateBy(x: 0, y: s)
    context.scaleBy(x: s / 1024, y: -s / 1024)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 184, cornerHeight: 184, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: colour(0x000000, 0.4))
    context.addPath(path)
    context.setFillColor(colour(0x0B0B0C))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: srgb, colors: [colour(0x232325), colour(0x0B0B0C)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    context.restoreGState()
    context.addPath(path)
    context.setStrokeColor(colour(0x3A3A3D))
    context.setLineWidth(5)
    context.strokePath()

    if size <= 32 {
        // Crisp whole-pixel cells: one pixel gap, as large as fits.
        let unit = 1024 / s
        let cell = size <= 16 ? 1.0 : 3.0
        let width = 3 * cell + 2, height = 5 * cell + 4
        let originX = ((s - width) / 2).rounded(), originY = ((s - height) / 2).rounded()
        context.setFillColor(colour(0xFF5A1F))
        for cell2 in pixelS {
            let x = originX + CGFloat(cell2[1]) * (cell + 1), y = originY + CGFloat(cell2[0]) * (cell + 1)
            context.fill(CGRect(x: x * unit, y: y * unit, width: cell * unit, height: cell * unit))
        }
        return context.makeImage()!
    }

    func centre(_ row: Int, _ column: Int) -> CGPoint {
        // The mockup's grid was 216...808 of a full-bleed 1024 tile; here the tile is 824 wide at an offset of 100.
        CGPoint(x: 100 + (216 + CGFloat(column) * 148) * 824 / 1024, y: 100 + (216 + CGFloat(row) * 148) * 824 / 1024)
    }
    func dot(_ point: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)
    }
    context.setFillColor(colour(0x2E2E31))
    for row in 0..<5 { for column in 0..<5 where !lit.contains([row, column]) { context.fillEllipse(in: dot(centre(row, column), radius: 24)) } }
    context.setFillColor(colour(0xFF5A1F))
    for key in lit {
        let point = centre(key[0], key[1])
        context.saveGState()
        context.setShadow(offset: .zero, blur: 18, color: colour(0xFF5A1F, 0.85))
        context.fillEllipse(in: dot(point, radius: 32))
        context.restoreGState()
        context.fillEllipse(in: dot(point, radius: 32))
    }
    return context.makeImage()!
}

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { fatalError("cannot write \(path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(path)") }
}

try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
var entries: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        write(render(pixels: points * scale), to: "\(outputDirectory)/\(name)")
        entries.append(
            "    { \"filename\" : \"\(name)\", \"idiom\" : \"mac\", \"scale\" : \"\(scale)x\", \"size\" : \"\(points)x\(points)\" }")
    }
}
let contents = "{\n  \"images\" : [\n" + entries.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try contents.write(toFile: "\(outputDirectory)/Contents.json", atomically: true, encoding: .utf8)
print("wrote \(entries.count) icons to \(outputDirectory)")
