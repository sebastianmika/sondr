import CoreText
import SwiftUI

/// IBM Plex Mono (SIL OFL, see `App/Fonts/OFL.txt`) for labels, numbers and readouts. The files ship in the app
/// bundle and are registered at launch; if that fails the system monospaced font stands in.
enum ThemeFonts {
    private static let files = ["IBMPlexMono-Regular", "IBMPlexMono-Medium", "IBMPlexMono-SemiBold"]

    static func register() {
        let urls = files.compactMap { Bundle.main.url(forResource: $0, withExtension: "ttf") }
        CTFontManagerRegisterFontsForURLs(urls as CFArray, .process, nil)
    }

    static func postScriptName(_ weight: Font.Weight) -> String {
        switch weight {
        case .semibold, .bold, .heavy, .black: "IBMPlexMono-SemiBold"
        case .medium: "IBMPlexMono-Medium"
        default: "IBMPlexMono"
        }
    }
}

extension Font {
    /// Plex Mono at `size` points (regular, medium or semibold), or the system monospaced font when it is not available.
    static func sondrMono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name = ThemeFonts.postScriptName(weight)
        return NSFont(name: name, size: size) != nil ? .custom(name, size: size) : .system(size: size, weight: weight, design: .monospaced)
    }
}

extension View {
    /// Section and column labels: caps, mono, wide-tracked, dim.
    func sondrLabel() -> some View {
        font(.sondrMono(size: 10.5, weight: .medium)).tracking(1.7).textCase(.uppercase).foregroundStyle(Theme.textDim)
    }
}
