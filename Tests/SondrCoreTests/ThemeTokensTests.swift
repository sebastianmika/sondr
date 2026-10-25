import Testing

@testable import SondrCore

private typealias RGB = ClusterPalette.RGB

private let grounds: [(String, ThemeColour)] = [
    ("window", ThemeTokens.window), ("panel", ThemeTokens.panel), ("surface", ThemeTokens.surface),
]

@Test(arguments: ThemeScheme.allCases)
func textTokensReachBodyContrastOnEveryGround(scheme: ThemeScheme) {
    let texts: [(String, ThemeColour)] = [
        ("text", ThemeTokens.text), ("textMid", ThemeTokens.textMid), ("textDim", ThemeTokens.textDim),
        ("signalText", ThemeTokens.signalText),
    ]
    for (textName, text) in texts {
        for (groundName, ground) in grounds {
            let ratio = text.value(for: scheme).contrast(against: ground.value(for: scheme))
            #expect(ratio >= 4.5, "\(textName) on \(groundName), \(scheme): \(ratio)")
        }
    }
}

@Test(arguments: ThemeScheme.allCases)
func signalReachesGraphicsContrastOnEveryGroundAndCarriesReadableText(scheme: ThemeScheme) {
    for (groundName, ground) in grounds {
        let ratio = ThemeTokens.signal.value(for: scheme).contrast(against: ground.value(for: scheme))
        #expect(ratio >= 3, "signal on \(groundName), \(scheme): \(ratio)")
    }
    let onSignal = ThemeTokens.onSignal.value(for: scheme).contrast(against: ThemeTokens.signal.value(for: scheme))
    #expect(onSignal >= 4.5, "onSignal on signal, \(scheme): \(onSignal)")
}

@Test func contrastIsSymmetricAndSpansOneToTwentyOne() {
    let (black, white) = (RGB(red: 0, green: 0, blue: 0), RGB(red: 255, green: 255, blue: 255))
    #expect(abs(black.contrast(against: white) - 21) < 1e-9)
    #expect(white.contrast(against: black) == black.contrast(against: white))
    #expect(white.contrast(against: white) == 1)
}

@Test func legibleLeavesGoodColoursAloneAndFixesYellowOnTheLightGround() {
    let light = ThemeTokens.window.light
    let blue = RGB(red: 0x1A, green: 0x4F, blue: 0xD6)
    #expect(blue.legible(on: light) == blue)

    let yellow = RGB(red: 0xFF, green: 0xB0, blue: 0x2E)
    #expect(yellow.contrast(against: light) < 3)
    let fixed = yellow.legible(on: light)
    #expect(fixed.contrast(against: light) >= 3)
    #expect(fixed.red >= fixed.green && fixed.green >= fixed.blue, "hue order kept")
    #expect(fixed.legible(on: light) == fixed, "idempotent")
}

@Test func legibleLightensDarkColoursOnTheDarkGround() {
    let dark = ThemeTokens.window.dark
    let navy = RGB(red: 0x10, green: 0x18, blue: 0x50)
    let fixed = navy.legible(on: dark)
    #expect(fixed.contrast(against: dark) >= 3)
    #expect(fixed.blue > navy.blue)
}

@Test func seedClusterColoursAreLegibleOnBothGroundsAfterAdjustment() throws {
    let seed = try ClusterCentres.seed()
    for scheme in ThemeScheme.allCases {
        let ground = ThemeTokens.clusterGround.value(for: scheme)
        for cluster in seed {
            let colour = try #require(RGB(hex: cluster.color)).legible(on: ground)
            #expect(colour.contrast(against: ground) >= 3, "\(cluster.name), \(scheme)")
        }
    }
}
