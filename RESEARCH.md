# Research: applying "Signal Grid" to Sondr

Findings from reading the code on 2026-10-25. Nothing was built or run.

## What the app is made of
- Native SwiftUI, macOS 15+, no custom window chrome. `MainView` is a `NavigationSplitView` (sidebar `List`, `SampleListView` with a native `Table`, `DetailView`). Settings is a `TabView` of grouped `Form`s. Icons are SF Symbols.
- XcodeGen (`project.yml`), `GENERATE_INFOPLIST_FILE: YES`. There is **no asset catalog**: no AppIcon, no AccentColor, no colour sets.
- `swift test` covers `SondrCore` only. App views have no unit tests; `SnapshotHook` (`SONDR_SNAPSHOT=<png>`) is the way to look at the UI.

## Where colour comes from today
- System colours: `.accentColor` / `NSColor.controlAccentColor` (waveform played part, spectrogram baked into pixels in `DetailView.accentRGB`, banners, drag rectangle, selected tag chip, parallel coordinates), `.primary`, `.secondary.opacity(x)` for grounds (`MapView` 0.06, `DetailView` 0.12, `ParallelCoordinatesView` 0.05).
- Cluster colours: stored as `#RRGGBB` in the `clusters` table, seeded from `Sources/SondrCore/Resources/Clusters/clusters.json`, user-editable (Settings → Clusters). `clusterColor(_:_:)` in `SidebarView.swift` turns them into `Color`; `MapView` passes `app.palette.denseTable` into `MapRaster.render`, which blends dots with alpha onto a transparent image. So the map ground is a SwiftUI colour behind the raster and can follow the scheme.
- Pixels with colour baked in (re-render needed on appearance change): map raster, spectrogram image.

## What this means for the design
1. **Biggest risk: table selection.** `Table` draws its own selection (system accent fill, white text). Orange `#FF5A1F` with white text is about 3:1, and the mockup's "1 px ring on a dark row" is not available through the public API. The mockup is therefore not reachable 1:1 on the Table. Cheapest test: set `.tint` to the signal colour and look at the Table in both appearances (plan step 0). Fallbacks: accept the system selection with dark text where allowed; or reach the `NSTableView` (the code already does this in `TableScroller`) for a custom row view.
2. **System accent overrides an app accent.** An `AccentColor` asset only applies when the user's system accent is "Multicolor". To make orange fixed, set `.tint(...)` on the root and stop reading `controlAccentColor` (the spectrogram does).
3. **Light and dark are one mechanism.** `NSApp.appearance` set from a preference (nil = system) switches the whole app including Settings and the Table. Tokens as dynamic `NSColor`s then resolve on their own. No view needs `@Environment(\.colorScheme)` except where pixels are baked.
4. **Cluster colours need a legibility rule in light mode.** The seed yellows and limes are below 3:1 on a light ground. Deriving a display colour per scheme (stored value untouched) is pure logic and fits `SondrCore` with unit tests.
5. **App icon needs new plumbing:** asset catalog with `AppIcon`, `ASSETCATALOG_COMPILER_APPICON_NAME`, a generator from SVG. Nothing exists to build on.
6. **Fonts:** IBM Plex Mono is not on macOS. Bundling needs registration (`CTFontManagerRegisterFontsForURLs` at launch) and its OFL licence file in the repo.

## Not checked
No build, no rendering of the existing UI, no look at Xcode's icon tooling output. Contrast numbers in `docs/DESIGN.md` are hand-computed and must be confirmed by the test in plan step 1.
