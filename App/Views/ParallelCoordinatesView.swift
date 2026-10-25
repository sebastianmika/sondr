import SondrCore
import SwiftUI

/// Six vertical axes (the audio dims) with one line per sample. Drag on an axis to keep only the
/// samples in that range; click an axis to clear its brush. Draws a bounded sample of lines;
/// the table filter always applies to the whole library.
struct ParallelCoordinatesView: View {
    @Environment(AppModel.self) private var app
    @Bindable var browse: BrowseModel
    @State private var context: DimSample?
    @State private var matching: DimSample?
    @State private var live: (dim: Dim, range: ClosedRange<Double>)?

    private let dims = Dim.allCases
    private let topInset: CGFloat = 22
    private let bottomInset: CGFloat = 8

    /// Reload when the filter or the library changes.
    private struct Key: Equatable {
        var filter: SampleFilter
        var version: Int
    }

    var body: some View {
        Canvas { canvas, size in
            let plot = CGRect(x: 30, y: topInset, width: size.width - 60, height: size.height - topInset - bottomInset)
            func x(_ index: Int) -> CGFloat { plot.minX + plot.width * CGFloat(index) / CGFloat(dims.count - 1) }
            func y(_ value: Double) -> CGFloat { plot.maxY - plot.height * CGFloat(value) }

            func draw(_ sample: DimSample?, color: Color) {
                guard let sample else { return }
                // Small batches: one huge path is very slow for the software renderer.
                for batch in stride(from: 0, to: sample.lines.count, by: 50) {
                    var path = Path()
                    for line in sample.lines[batch..<min(batch + 50, sample.lines.count)] {
                        for (i, value) in line.enumerated() {
                            let point = CGPoint(x: x(i), y: y(value))
                            i == 0 ? path.move(to: point) : path.addLine(to: point)
                        }
                    }
                    canvas.stroke(path, with: .color(color), lineWidth: 0.7)
                }
            }
            let brushed = !browse.filter.dimRanges.isEmpty
            draw(context, color: .secondary.opacity(brushed ? 0.07 : 0.14))
            if brushed { draw(matching, color: .accentColor.opacity(0.25)) }

            for (i, dim) in dims.enumerated() {
                canvas.stroke(Path { $0.move(to: CGPoint(x: x(i), y: plot.minY)); $0.addLine(to: CGPoint(x: x(i), y: plot.maxY)) },
                    with: .color(.secondary), lineWidth: 1)
                canvas.draw(Text(dim.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary),
                    at: CGPoint(x: x(i), y: topInset / 2), anchor: .center)
                let range = live?.dim == dim ? live?.range : browse.filter.dimRanges[dim]
                if let range {
                    let rect = CGRect(x: x(i) - 5, y: y(range.upperBound), width: 10, height: max(y(range.lowerBound) - y(range.upperBound), 2))
                    canvas.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(.accentColor.opacity(0.55)))
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let total = (browse.filter.dimRanges.isEmpty ? context : matching)?.total {
                Text("\(total) samples with sound data").font(.caption2).foregroundStyle(.secondary).padding(4)
            }
        }
        .gesture(brushGesture)
        .background(Color.secondary.opacity(0.05))
        .background(GeometryReader { proxy in Color.clear.onAppear { canvasSize = proxy.size }.onChange(of: proxy.size) { _, new in canvasSize = new } })
        .task(id: Key(filter: browse.filter, version: app.libraryVersion)) { await load() }
        .help("Drag on an axis to keep only samples in that range. Click an axis to clear it.")
    }

    private var brushGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { value in
            guard let (dim, size) = target(for: value.startLocation) else { return }
            let plotHeight = size.height - topInset - bottomInset
            func normalised(_ y: CGFloat) -> Double { min(max(Double((size.height - bottomInset - y) / plotHeight), 0), 1) }
            let a = normalised(value.startLocation.y), b = normalised(value.location.y)
            live = (dim, min(a, b)...max(a, b))
        }.onEnded { value in
            defer { live = nil }
            guard let (dim, _) = target(for: value.startLocation) else { return }
            let moved = hypot(value.translation.width, value.translation.height)
            if moved < 3 {
                browse.filter.dimRanges[dim] = nil
            } else if let live, live.dim == dim {
                browse.filter.dimRanges[dim] = live.range
            }
        }
    }

    @State private var canvasSize = CGSize(width: 600, height: 180)

    /// The axis nearest to the point, if it is close enough.
    private func target(for point: CGPoint) -> (Dim, CGSize)? {
        let size = canvasSize
        let plotWidth = size.width - 60
        let step = plotWidth / CGFloat(dims.count - 1)
        let index = Int(((point.x - 30) / step).rounded())
        guard dims.indices.contains(index), abs(point.x - (30 + step * CGFloat(index))) < 16 else { return nil }
        return (dims[index], size)
    }

    private func load() async {
        guard let database = app.database else { return }
        let base: SampleFilter = {
            var f = browse.filter
            f.dimRanges = [:]
            return f
        }()
        let full = browse.filter
        let brushed = !full.dimRanges.isEmpty
        let result = try? await database.writer.read { db in
            (try SampleQuery.dimSample(db, filter: base, limit: 1500),
             brushed ? try SampleQuery.dimSample(db, filter: full, limit: 1500) : nil)
        }
        context = result?.0
        matching = result?.1
    }
}
