import SondrCore
import SwiftUI

/// Settings → Map: every setting of the 2D map with an explanation, and what the current map was built with.
struct MapSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let map = app.map {
            MapSettingsForm(map: map)
        } else {
            ContentUnavailableView("No library open", systemImage: "map")
        }
    }
}

private struct MapSettingsForm: View {
    let map: MapModel

    private var parameters: Binding<MapParameters> {
        Binding(get: { map.saved }, set: { map.saveSettings($0) })
    }

    var body: some View {
        Form {
            currentMap
            layout
            advanced
            reading
        }
        .formStyle(.grouped)
    }

    // MARK: Current map

    private var currentMap: some View {
        Section("Current map") {
            if let current = map.current {
                LabeledContent("Built") { Text(current.createdAt.formatted(date: .abbreviated, time: .shortened)) }
                LabeledContent("Samples") {
                    Text("\(current.pointCount.formatted()) (layout from \(current.fittedCount.formatted()), the rest placed)")
                }
                LabeledContent("Settings") { Text(summary(current.parameters)).foregroundStyle(.secondary) }
                if let hint = map.rebuildHint { Label(hint, systemImage: "arrow.triangle.2.circlepath").font(.callout) }
            } else {
                Text(map.canBuild ? "There is no map yet." : "A map needs at least \(MapParameters.minimumSamples) indexed samples.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Rebuild with a preview…") {
                    map.requestLayoutPanel()
                    NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                }
                .disabled(!map.canBuild)
                Button("Restore previous map") { Task { await map.restorePrevious() } }
                    .disabled(!map.hasPrevious)
            }
            Text("The settings below apply the next time a map is built. To try values and see the result before it replaces the map, use Layout on the map view.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func summary(_ p: MapParameters) -> String {
        "neighbourhood \(Int(p.perplexity)), tightness \(Int(p.earlyExaggeration)), \(p.iterations) steps, sample \(p.sampleSize.formatted())"
    }

    // MARK: Main settings

    private var layout: some View {
        Section("Layout") {
            ParameterRow(
                title: "Sample size", value: "\(parameters.wrappedValue.sampleSize.formatted())",
                explanation: "How many randomly chosen samples the layout is computed from. All other samples are placed onto it afterwards, which is fast. More samples show more detail and take longer: about 1 s for 25,000 and 2 s for 50,000 on an M4 Pro. A library with fewer samples uses all of them."
            ) {
                Slider(value: intBinding(parameters.sampleSize), in: 1_000...50_000, step: 1_000)
            }
            LabeledContent("Random sample") {
                Button("Pick a different one") { var p = parameters.wrappedValue; p.seed = UInt64.random(in: 1...UInt64.max); map.saveSettings(p) }
            }
            Text("Chooses another random set of samples for the layout. It also changes the starting point of the layout.")
                .font(.caption).foregroundStyle(.secondary)
            ParameterRow(
                title: "Neighbourhood size", value: "\(Int(parameters.wrappedValue.perplexity))",
                explanation: "Roughly how many neighbours each sample is drawn towards. Low values give many small, tight groups. High values give fewer, broader ones. 30 suits most libraries."
            ) {
                Slider(value: parameters.perplexity, in: MapParameters.perplexityRange, step: 1)
            }
            ParameterRow(
                title: "Cluster tightness", value: "\(Int(parameters.wrappedValue.earlyExaggeration))",
                explanation: "How strongly groups are pulled together during the first steps. Higher values make groups tighter and more separated at the start. It changes the final picture less than the neighbourhood size does."
            ) {
                Slider(value: parameters.earlyExaggeration, in: MapParameters.earlyExaggerationRange, step: 1)
            }
            ParameterRow(
                title: "Refinement steps", value: "\(parameters.wrappedValue.iterations)",
                explanation: "How long the layout is refined. More steps give a cleaner result and take longer. 300 already gives a clean layout for most libraries."
            ) {
                Slider(value: intBinding(parameters.iterations), in: Double(MapParameters.iterationsRange.lowerBound)...Double(MapParameters.iterationsRange.upperBound), step: 50)
            }
            Toggle("Reduce the vectors first", isOn: Binding(
                get: { parameters.wrappedValue.pcaDimensions != nil },
                set: { var p = parameters.wrappedValue; p.pcaDimensions = $0 ? 50 : nil; map.saveSettings(p) }))
            Text("Shortens each sample's list of numbers before the layout is computed. Faster and less noisy; turn it off to use every number.")
                .font(.caption).foregroundStyle(.secondary)
            if let dimensions = parameters.wrappedValue.pcaDimensions {
                ParameterRow(
                    title: "Reduce to", value: "\(dimensions) numbers",
                    explanation: "Each sample is described by 512 numbers. They are first reduced to this many, which makes the neighbour search faster and removes noise. 50 is a common choice."
                ) {
                    Slider(
                        value: Binding(get: { Double(dimensions) }, set: { var p = parameters.wrappedValue; p.pcaDimensions = Int($0); map.saveSettings(p) }),
                        in: Double(MapParameters.pcaRange.lowerBound)...Double(MapParameters.pcaRange.upperBound), step: 5)
                }
            }
        }
    }

    // MARK: Advanced

    private var advanced: some View {
        Section {
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Choose the number of neighbours myself", isOn: Binding(
                        get: { parameters.wrappedValue.neighborCount != nil },
                        set: { var p = parameters.wrappedValue; p.neighborCount = $0 ? Int(3 * p.perplexity) : nil; map.saveSettings(p) }))
                    Text("Off: the number of neighbours follows the neighbourhood size.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let count = parameters.wrappedValue.neighborCount {
                        ParameterRow(
                            title: "Neighbours kept", value: "\(count)",
                            explanation: "How many neighbours are looked up per sample. Normally three times the neighbourhood size. More is more exact and slower."
                        ) {
                            Slider(value: Binding(get: { Double(count) }, set: { var p = parameters.wrappedValue; p.neighborCount = Int($0); map.saveSettings(p) }), in: 15...300, step: 5)
                        }
                    }
                    ParameterRow(
                        title: "Steps with tightness applied", value: "\(parameters.wrappedValue.earlyExaggerationIterations)",
                        explanation: "How many of the first steps use the cluster tightness above. Cannot be more than the refinement steps."
                    ) {
                        Slider(value: intBinding(parameters.earlyExaggerationIterations), in: 0...Double(parameters.wrappedValue.iterations), step: 10)
                    }
                    Toggle("Choose the learning rate myself", isOn: Binding(
                        get: { parameters.wrappedValue.learningRate != nil },
                        set: { var p = parameters.wrappedValue; p.learningRate = $0 ? 200 : nil; map.saveSettings(p) }))
                    Text("Off: the learning rate is chosen from the sample size.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let rate = parameters.wrappedValue.learningRate {
                        ParameterRow(
                            title: "Learning rate", value: "\(Int(rate))",
                            explanation: "How far points move per step. Normally chosen from the sample size. Too low and groups stay mushy, too high and the picture jumps around."
                        ) {
                            Slider(value: Binding(get: { rate }, set: { var p = parameters.wrappedValue; p.learningRate = $0; map.saveSettings(p) }), in: 10...2_000, step: 10)
                        }
                    }
                    ParameterRow(
                        title: "Momentum at first", value: String(format: "%.2f", parameters.wrappedValue.initialMomentum),
                        explanation: "How much of the previous movement carries over during the first steps."
                    ) {
                        Slider(value: parameters.initialMomentum, in: 0...0.95, step: 0.05)
                    }
                    ParameterRow(
                        title: "Momentum later", value: String(format: "%.2f", parameters.wrappedValue.finalMomentum),
                        explanation: "The same for the remaining steps."
                    ) {
                        Slider(value: parameters.finalMomentum, in: 0...0.95, step: 0.05)
                    }
                    Picker("Start layout", selection: parameters.initialization) {
                        Text("From the main directions (steadier)").tag(MapInitialization.pca)
                        Text("Random").tag(MapInitialization.random)
                    }
                    Text("Where the points start before they are moved. The main directions give a steadier result; random can find other arrangements.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Calculation", selection: parameters.backend) {
                        Text("Automatic").tag(MapBackend.auto)
                        Text("Always exact").tag(MapBackend.exact)
                        Text("Always fast approximation").tag(MapBackend.fast)
                    }
                    Text("Automatic uses exact calculations up to 10,000 samples and fast approximations above. Exact is slower with larger samples.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Seed") {
                        TextField("Seed", value: parameters.seed, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing).frame(width: 140)
                    }
                    Text("Decides which samples are chosen and how the layout starts. The same seed picks the same samples, but two layouts from the same seed can still differ a little.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reset all map settings") { map.saveSettings(MapParameters()) }
                }
                .padding(.top, 6)
            }
        }
    }

    // MARK: Reading the map

    private var reading: some View {
        Section("Reading the map") {
            Text("The map is a t-SNE layout. It shows which samples sit among similar ones. How far apart two groups are, how large a group looks and how empty the space between groups is do not carry meaning. Building the map again can arrange the same groups differently.")
                .font(.callout)
        }
    }

    private func intBinding(_ binding: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0.rounded()) })
    }
}

/// A title with its current value, the control, and a caption that explains it.
struct ParameterRow<Control: View>: View {
    let title: String
    let value: String
    let explanation: String
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(value).font(.sondrMono(size: 12)).foregroundStyle(.secondary)
            }
            control
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
