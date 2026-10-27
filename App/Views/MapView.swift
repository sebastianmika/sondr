import SondrCore
import SwiftUI

/// The 2D map: one dot per sample, coloured by cluster. Drag to pick an area (it narrows the list),
/// click a dot to select it, scroll to move, pinch or hold command and scroll to zoom, double-click to
/// show everything. The Layout card tries other settings and shows the result before anything is replaced.
struct MapCanvasView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme
    let browse: BrowseModel
    @Binding var selection: Set<Int64>
    @State private var viewport: MapViewport?
    @State private var fit: MapViewport?
    @State private var image: CGImage?
    /// The whole panel; the map itself is `size`, which leaves room for the Layout card when it is open.
    @State private var outer = CGSize(width: 400, height: 300)
    @State private var hover: (index: Int, point: CGPoint)?
    @State private var hoverName: String?
    @State private var dragRect: (CGPoint, CGPoint)?
    @State private var showLayout = false
    @State private var comparing = false
    @State private var optionHeld = false
    @State private var selectedIndices: [Int] = []

    static let cardWidth: CGFloat = 290

    private var size: CGSize {
        CGSize(width: max(outer.width - (showLayout ? Self.cardWidth + 16 : 0), 10), height: max(outer.height, 10))
    }

    private var map: MapModel? { app.map }

    /// What is drawn: the preview while tuning, the current map otherwise (or while comparing).
    private var showsPreview: Bool {
        guard let map, map.isTuning, map.previewDots != nil else { return false }
        return !(comparing || optionHeld)
    }

    private var dots: MapDots? { showsPreview ? map?.previewDots : map?.dots }

    private var effective: MapViewport { viewport ?? fit ?? MapViewport(centre: .zero, scale: 1) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.window
            Group {
                if let map, dots != nil {
                    canvas(map)
                } else if let map {
                    emptyState(map)
                }
            }
            // The Layout card sits beside the map instead of on top of it.
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            if let map {
                overlays(map)
            }
        }
        .clipped()
        .background(
            GeometryReader { proxy in Color.clear.onAppear { outer = proxy.size }.onChange(of: proxy.size) { _, new in outer = new } })
        .task(id: FitKey(base: map?.current?.id, hasPreview: map?.preview != nil, hasDots: map?.dots != nil, size: size)) {
            await computeFit()
        }
        .task(id: renderKey) { await render() }
        .task(id: SelectionKey(revision: map?.revision ?? 0, comparing: showsPreview, selection: selection)) {
            selectedIndices = indices(of: selection)
        }
        .task(id: hover?.index) { await loadHoverName() }
        .onChange(of: map?.layoutPanelRequested ?? false) { _, requested in
            if requested {
                showLayout = true
                map?.layoutPanelRequested = false
            }
        }
        .onChange(of: showLayout) { _, open in
            guard let map else { return }
            if open {
                map.beginTuning()
                if map.current == nil { map.requestPreview() }
            } else {
                map.endTuning()
                comparing = false
            }
        }
        .onDisappear { map?.endTuning() }
        .task {
            // Development aids for snapshots (see SnapshotHook): open the Layout card, optionally with a changed setting.
            let environment = ProcessInfo.processInfo.environment
            guard environment["SONDR_SHOW_LAYOUT"] != nil else { return }
            try? await Task.sleep(for: .seconds(1))
            showLayout = true
            if let perplexity = environment["SONDR_PREVIEW_PERPLEXITY"].flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(0.5))
                map?.draft.perplexity = perplexity
            }
        }
    }

    // MARK: Drawing

    private struct FitKey: Hashable {
        let base: Int64?
        let hasPreview: Bool
        let hasDots: Bool
        let size: CGSize
    }

    private struct SelectionKey: Hashable {
        let revision: Int
        let comparing: Bool
        let selection: Set<Int64>
    }

    private struct RenderKey: Hashable {
        let revision: Int
        let showsPreview: Bool
        let highlight: Int
        let colours: [String]
        let size: CGSize
        let centreX: Float
        let centreY: Float
        let scale: Float
        let displayScale: CGFloat
        let colorScheme: ColorScheme
    }

    private var renderKey: RenderKey {
        RenderKey(
            revision: map?.revision ?? 0, showsPreview: showsPreview, highlight: browse.highlightRevision, colours: app.clusters.map(\.color), size: size,
            centreX: effective.centre.x, centreY: effective.centre.y, scale: effective.scale, displayScale: displayScale,
            colorScheme: colorScheme)
    }

    private func computeFit() async {
        guard let map, let source = map.dots ?? map.previewDots, size.width > 10 else { return }
        let width = Float(size.width), height = Float(size.height)
        let result = await Task.detached(priority: .userInitiated) {
            MapViewport.fitting(x: source.x, y: source.y, size: SIMD2(width, height))
        }.value
        fit = result
    }

    private func render() async {
        guard let dots, size.width > 10, size.height > 10 else {
            image = nil
            return
        }
        let ratio = Float(displayScale)
        let width = Int(size.width * displayScale), height = Int(size.height * displayScale)
        let scaled = MapViewport(centre: effective.centre, scale: effective.scale * ratio)
        let highlight = showsPreview ? nil : browse.highlight
        // Colours are baked into the picture, so they are made legible for the current ground here and the picture is redrawn when the scheme changes.
        let ground = ThemeTokens.clusterGround.value(for: Theme.scheme(colorScheme))
        let colours = app.palette.denseTable.map { $0.legible(on: ground) }
        let bytes = await Task.detached(priority: .userInitiated) {
            MapRaster.render(dots, colours: colours, viewport: scaled, width: width, height: height, highlight: highlight, radius: nil)
        }.value
        guard !Task.isCancelled, let provider = CGDataProvider(data: Data(bytes) as CFData) else { return }
        image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func canvas(_ map: MapModel) -> some View {
        ZStack(alignment: .topLeading) {
            if let image {
                // Resizable, so that the picture's own size (it is drawn a moment behind the view's) never affects the layout.
                Image(decorative: image, scale: displayScale).resizable().interpolation(.none)
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            ForEach(selectedIndices.prefix(60), id: \.self) { index in
                if let dots, index < dots.count {
                    let p = effective.toPixel(SIMD2(dots.x[index], dots.y[index]), size: SIMD2(Float(size.width), Float(size.height)))
                    Circle().strokeBorder(Theme.text, lineWidth: 2).background(Circle().fill(.clear))
                        .frame(width: 14, height: 14).position(x: CGFloat(p.x), y: CGFloat(p.y)).allowsHitTesting(false)
                }
            }
            if let rect = dragRect {
                let frame = CGRect(
                    x: min(rect.0.x, rect.1.x), y: min(rect.0.y, rect.1.y), width: abs(rect.0.x - rect.1.x), height: abs(rect.0.y - rect.1.y))
                Rectangle().fill(Theme.signal.opacity(0.12)).overlay(Rectangle().stroke(Theme.signal, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY).allowsHitTesting(false)
            }
            if let hover, let dots, hover.index < dots.count {
                Text(hoverName ?? " ").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 2))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.hairline, lineWidth: 1))
                    .fixedSize().position(x: min(hover.point.x + 14 + 70, size.width - 70), y: max(hover.point.y - 14, 12))
                    .opacity(hoverName == nil ? 0 : 1).allowsHitTesting(false)
            }
            MapInteractionView(
                onMove: { point in
                    if let point { hover = nearest(to: point).map { ($0, point) } } else { hover = nil }
                },
                onClick: { point in
                    if let index = nearest(to: point), let dots { select(dots.ids[index]) } else { selection = [] }
                },
                onDoubleClick: { viewport = nil },
                onDrag: { start, now in dragRect = (start, now) },
                onDragEnd: { start, now in
                    dragRect = nil
                    pickArea(from: start, to: now)
                },
                onScroll: { delta, point, flags in
                    if flags.contains(.command) || flags.contains(.option) {
                        zoom(by: Float(exp(delta.height * 0.02)), around: point)
                    } else {
                        viewport = effective.panned(by: SIMD2(Float(delta.width), Float(delta.height)))
                    }
                },
                onMagnify: { delta, point in zoom(by: Float(1 + delta), around: point) },
                onEscape: {
                    browse.filter.sampleIDs = nil
                    selection = []
                },
                onOptionKey: { optionHeld = $0 })
        }
    }

    // MARK: Interaction

    private func nearest(to point: CGPoint) -> Int? {
        guard let dots else { return nil }
        return MapRaster.nearest(
            in: dots, to: SIMD2(Float(point.x), Float(point.y)), viewport: effective,
            size: SIMD2(Float(size.width), Float(size.height)), maxDistance: 9)
    }

    private func select(_ id: Int64) {
        selection = [id]
    }

    private func zoom(by factor: Float, around point: CGPoint) {
        viewport = effective.zoomed(
            by: factor, around: SIMD2(Float(point.x), Float(point.y)), size: SIMD2(Float(size.width), Float(size.height)))
    }

    private func pickArea(from start: CGPoint, to end: CGPoint) {
        guard let dots else { return }
        let inside = MapRaster.indices(
            in: dots, rect: (SIMD2(Float(start.x), Float(start.y)), SIMD2(Float(end.x), Float(end.y))), viewport: effective,
            size: SIMD2(Float(size.width), Float(size.height)))
        if !inside.isEmpty { browse.filter.sampleIDs = Set(inside.map { dots.ids[$0] }) }
    }

    private func indices(of ids: Set<Int64>) -> [Int] {
        guard let dots, !ids.isEmpty, ids.count <= 200 else { return [] }
        return dots.ids.indices.filter { ids.contains(dots.ids[$0]) }
    }

    private func loadHoverName() async {
        hoverName = nil
        guard let index = hover?.index, let dots, index < dots.count, let database = app.database else { return }
        let id = dots.ids[index]
        let name = try? await database.writer.read { try SampleQuery.rows($0, ids: [id]).first?.name }
        if !Task.isCancelled { hoverName = name }
    }

    // MARK: Overlays and empty state

    @ViewBuilder private func emptyState(_ map: MapModel) -> some View {
        VStack(spacing: 8) {
            if case .computing = map.phase {
                ProgressView().controlSize(.small)
                Text("Computing the first layout…").foregroundStyle(.secondary)
            } else if map.canBuild {
                Image(systemName: "map").font(.largeTitle).foregroundStyle(.secondary)
                Text("There is no map yet.").font(.headline)
                Button("Build the map…") { showLayout = true }.buttonStyle(.borderedProminent)
            } else {
                Image(systemName: "map").font(.largeTitle).foregroundStyle(.secondary)
                Text("The map needs at least \(MapParameters.minimumSamples) indexed samples.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func overlays(_ map: MapModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                statusChip(map)
                Spacer()
                if map.canBuild {
                    Button { showLayout.toggle() } label: { Label("Layout", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Try other layout settings and see the result before it replaces the map")
                }
            }
            if showLayout {
                HStack {
                    Spacer()
                    ScrollView { LayoutCard(map: map, comparing: $comparing, close: { showLayout = false }) }
                        .scrollIndicators(.never)
                        .frame(width: Self.cardWidth)
                }
            }
            Spacer(minLength: 0)
            HStack {
                if let dots {
                    Text("\(dots.count.formatted()) samples").font(.sondrMono(size: 10.5)).foregroundStyle(Theme.textDim)
                }
                if let hint = map.rebuildHint, !showLayout {
                    Label("Library has grown. Rebuild?", systemImage: "arrow.triangle.2.circlepath").font(.caption)
                        .help(hint).onTapGesture { showLayout = true }
                }
                Spacer()
                if viewport != nil { Button("Show all") { viewport = nil }.buttonStyle(.link).font(.caption) }
            }
        }
        .padding(8)
    }

    @ViewBuilder private func statusChip(_ map: MapModel) -> some View {
        if showsPreview {
            chip(map.phase == .previewing ? "Preview, not saved" : "Computing preview…", tint: Theme.signal, text: Theme.onSignal)
        } else if map.isTuning, map.previewDots != nil, comparing || optionHeld {
            chip("Current map", tint: .secondary)
        }
    }

    private func chip(_ text: String, tint: Color, text textColor: Color = .white) -> some View {
        Text(text).font(.caption.bold()).foregroundStyle(textColor).padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint, in: RoundedRectangle(cornerRadius: 2))
    }
}

/// The settings that matter most while looking at the map. A change computes a new preview; Keep
/// saves it, Discard drops it. The explanations of every setting are in Settings → Map.
private struct LayoutCard: View {
    let map: MapModel
    @Binding var comparing: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Layout").font(.headline)
                Spacer()
                Button { close() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Close; a preview that was not kept is dropped")
            }
            slider("Sample size", "\(map.draft.sampleSize.formatted())", value: intBinding(\.sampleSize), range: 1_000...50_000, step: 1_000)
            slider("Neighbourhood size", "\(Int(map.draft.perplexity))", value: Binding(get: { map.draft.perplexity }, set: { map.draft.perplexity = $0 }), range: MapParameters.perplexityRange, step: 1)
            slider("Cluster tightness", "\(Int(map.draft.earlyExaggeration))", value: Binding(get: { map.draft.earlyExaggeration }, set: { map.draft.earlyExaggeration = $0 }), range: MapParameters.earlyExaggerationRange, step: 1)
            slider("Refinement steps", "\(map.draft.iterations)", value: intBinding(\.iterations), range: 100...1_000, step: 50)
            HStack {
                Button("New random sample") { map.draft.seed = UInt64.random(in: 1...UInt64.max) }
                Button("Reset") { map.draft = MapParameters() }
                Spacer()
            }
            .controlSize(.small)
            status
            HStack {
                Button("Keep") { Task { await map.keep() } }
                    .buttonStyle(.borderedProminent).disabled(map.phase != .previewing)
                    .keyboardShortcut(.return, modifiers: [])
                Button("Discard") { map.discard() }.disabled(map.preview == nil && map.phase == .idle)
                if map.current != nil {
                    Toggle("Show current", isOn: $comparing).toggleStyle(.button).disabled(map.previewDots == nil)
                        .help("Flip between the preview and the current map. Holding ⌥ does the same.")
                }
            }
            .controlSize(.small)
            HStack {
                if map.hasPrevious {
                    Button("Restore previous map") { Task { await map.restorePrevious() } }.buttonStyle(.link)
                }
                Spacer()
                SettingsLink { Text("More settings…") }.buttonStyle(.link)
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: MapCanvasView.cardWidth)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
    }

    @ViewBuilder private var status: some View {
        switch map.phase {
        case .idle:
            Text(map.current == nil ? "Change a setting to compute a preview." : "Change a setting to try another layout.")
                .font(.caption).foregroundStyle(.secondary)
        case .computing(let done, let total):
            HStack(spacing: 6) {
                if total > 0 { ProgressView(value: Double(done), total: Double(total)) } else { ProgressView().controlSize(.small) }
                Text(total > 0 ? "\(done) of \(total) steps" : "Preparing…").font(.caption).foregroundStyle(.secondary)
            }
        case .previewing:
            if let preview = map.preview {
                Text("Preview of \(preview.sampleIDs.count.formatted()) samples, \(String(format: "%.1f", preview.seconds)) s"
                    + (preview.isAligned ? ", matched to the current map" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .working(let text):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Text(reason).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func slider(_ title: String, _ value: String, value binding: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range, step: step).controlSize(.small)
        }
    }

    private func intBinding(_ keyPath: WritableKeyPath<MapParameters, Int>) -> Binding<Double> {
        Binding(get: { Double(map.draft[keyPath: keyPath]) }, set: { map.draft[keyPath: keyPath] = Int($0.rounded()) })
    }
}
