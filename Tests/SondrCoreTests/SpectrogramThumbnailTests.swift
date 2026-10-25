import Foundation
import GRDB
import Testing

@testable import SondrCore

private let rate = Float(ClapMelExtractor.sampleRate)

private func sine(_ hz: Float, seconds: Float = 1, amplitude: Float = 0.8) -> [Float] {
    (0..<Int(seconds * rate)).map { amplitude * sin(2 * .pi * hz * Float($0) / rate) }
}

/// Column `c` of the thumbnail (time-major layout).
private func column(_ thumb: [UInt8], _ c: Int) -> [UInt8] {
    let bands = SpectrogramThumbnail.bands
    return Array(thumb[(c * bands)..<((c + 1) * bands)])
}

@Test(arguments: [0, 1, 5, 100, 1023, 1024, 48_000, 480_000])
func spectrogramHasConstantLength(count: Int) {
    let audio = (0..<count).map { Float(sin(Double($0) * 0.01)) }
    #expect(SpectrogramThumbnail.make(audio: audio).count == SpectrogramThumbnail.columns * SpectrogramThumbnail.bands)
}

@Test func spectrogramOfSilenceIsZero() {
    let size = SpectrogramThumbnail.columns * SpectrogramThumbnail.bands
    #expect(SpectrogramThumbnail.make(audio: [Float](repeating: 0, count: 48_000)) == [UInt8](repeating: 0, count: size))
    #expect(SpectrogramThumbnail.make(audio: []) == [UInt8](repeating: 0, count: size))
}

@Test(arguments: [(220 as Float), 1000, 4000, 10_000])
func aSineLightsUpTheBandOfItsFrequencyInEveryColumn(hz: Float) {
    let thumb = SpectrogramThumbnail.make(audio: sine(hz))
    let expected = SpectrogramThumbnail.band(forFrequency: Double(hz))
    for c in [2, 20, 40, 60] {
        let col = column(thumb, c)
        let loudest = col.indices.max { col[$0] < col[$1] }!
        #expect(abs(loudest - expected) <= 1, "\(hz) Hz, column \(c): band \(loudest), expected \(expected)")
        #expect(col[loudest] > 200)
    }
}

@Test func higherFrequenciesLandInHigherBands() {
    let bands = [200, 800, 3200, 12_800].map { SpectrogramThumbnail.band(forFrequency: Double($0)) }
    #expect(bands == bands.sorted() && Set(bands).count == 4)
    #expect(bands.first! >= 0 && bands.last! < SpectrogramThumbnail.bands)
}

@Test func aBurstAtTheStartIsBrightOnTheLeftAndDarkOnTheRight() {
    var audio = [Float](repeating: 0, count: 48_000)
    for i in 0..<4800 { audio[i] = 0.9 * sin(2 * .pi * 1000 * Float(i) / rate) }
    let thumb = SpectrogramThumbnail.make(audio: audio)
    let band = SpectrogramThumbnail.band(forFrequency: 1000)
    #expect(column(thumb, 1)[band] > 200)
    #expect(column(thumb, 60)[band] < 20)
}

@Test func spectrogramIgnoresOverallLoudness() {
    let loud = SpectrogramThumbnail.make(audio: sine(1000, amplitude: 0.9))
    let quiet = SpectrogramThumbnail.make(audio: sine(1000, amplitude: 0.09))
    #expect(zip(loud, quiet).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
}

@Test func spectrogramOfFixturesIsDeterministicAndShowsStructure() throws {
    let kick = try AudioLoader.load(url: Fixtures.url("audio/kick_short.wav"))
    let first = SpectrogramThumbnail.make(audio: kick)
    #expect(first == SpectrogramThumbnail.make(audio: kick))
    #expect(first.max()! > 200)
    #expect(Set(first).count > 20)  // not flat
}

// MARK: Rendering (accent ramp)

private let accent = (red: UInt8(40), green: UInt8(120), blue: UInt8(240))

@Test func rampIsTransparentForSilenceAndOpaqueAccentForTheLoudestCell() throws {
    let size = SpectrogramThumbnail.columns * SpectrogramThumbnail.bands
    var thumb = [UInt8](repeating: 0, count: size)
    thumb[0] = 255
    let pixels = try #require(SpectrogramThumbnail.pixels(from: Data(thumb), accent: accent))
    #expect(pixels.count == size * 4)
    // thumb[0] is column 0, band 0 (lowest): bottom-left pixel.
    let bottomLeft = (SpectrogramThumbnail.bands - 1) * SpectrogramThumbnail.columns * 4
    #expect(Array(pixels[bottomLeft..<(bottomLeft + 4)]) == [40, 120, 240, 255])
    #expect(Array(pixels[0..<4]) == [0, 0, 0, 0])  // top-left, silent
}

@Test func rampGetsMoreOpaqueWithLevelAndStaysPremultiplied() throws {
    let bands = SpectrogramThumbnail.bands
    var thumb = [UInt8](repeating: 0, count: SpectrogramThumbnail.columns * bands)
    for (column, level) in [0, 64, 128, 192, 255].enumerated() { thumb[column * bands] = UInt8(level) }
    let pixels = try #require(SpectrogramThumbnail.pixels(from: Data(thumb), accent: accent))
    let bottom = (bands - 1) * SpectrogramThumbnail.columns * 4
    let alphas = (0..<5).map { pixels[bottom + $0 * 4 + 3] }
    #expect(alphas == alphas.sorted() && Set(alphas).count == 5)
    for column in 0..<5 {
        let p = bottom + column * 4
        #expect(pixels[p + 2] <= pixels[p + 3], "premultiplied blue never exceeds alpha")
        #expect(abs(Int(pixels[p + 2]) - Int(Double(accent.blue) * Double(pixels[p + 3]) / 255)) <= 1)
    }
}

@Test func rampRejectsMissingOrWrongSizedData() {
    #expect(SpectrogramThumbnail.pixels(from: nil, accent: accent) == nil)
    #expect(SpectrogramThumbnail.pixels(from: Data([1, 2, 3]), accent: accent) == nil)
}

@Test func axisPositionsAreLogAndMatchTheBands() {
    #expect(SpectrogramThumbnail.axisPosition(forFrequency: 50) == 0)
    #expect(abs(SpectrogramThumbnail.axisPosition(forFrequency: 14_000) - 1) < 1e-9)
    let positions = [100, 1000, 10_000].map { SpectrogramThumbnail.axisPosition(forFrequency: Double($0)) }
    #expect(positions == positions.sorted())
    for hz in [100.0, 1000, 10_000] {
        let position = SpectrogramThumbnail.axisPosition(forFrequency: hz)
        #expect(Int(position * Double(SpectrogramThumbnail.bands)) == SpectrogramThumbnail.band(forFrequency: hz))
    }
}
