import SondrCore
import SwiftUI

/// Settings → Locations: folders in the library, their tags, and the blacklist for all of them.
struct LocationsSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false
    @State private var editing: LocationEditor.Mode?
    @State private var removing: LocationInfo?
    @State private var reviewing: LocationInfo?

    var body: some View {
        Form {
            Section("Locations") {
                if app.locations.isEmpty {
                    Text("No folders yet. Sondr reads the audio files in them and never changes them.")
                        .foregroundStyle(.secondary)
                }
                ForEach(app.locations) { location in
                    LocationRow(location: location, edit: { editing = .edit(location) }, review: { reviewing = location }, remove: { removing = location })
                }
                HStack {
                    Button("Add Location…") { importing = true }.disabled(busy)
                    Button("Rescan All") { Task { await app.rescanAll() } }
                        .disabled(busy || app.locations.isEmpty)
                    Button(app.stats.pending > 0 ? "Index \(app.stats.pending.formatted())" : "Index") {
                        Task { await app.startIndexing() }
                    }
                    .disabled(busy || app.stats.pending == 0 || !app.modelsAvailable)
                    .help(app.modelsAvailable ? "Compute embeddings for samples that have none" : "Core ML models not found")
                    if let status = progressText { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section {
                GlobalRulesEditor()
            } header: {
                Text("Ignored tags (all locations)")
            } footer: {
                Text("Tags matching these rules are not given to any sample from a path. Tags you add by hand and extra tags of a location are not affected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { editing = .add(url) }
        }
        .sheet(item: $editing) { mode in
            LocationEditor(mode: mode)
        }
        .sheet(item: $reviewing) { MultisampleEditorView(location: $0) }
        .confirmationDialog(
            "Remove “\(removing?.name ?? "")” from the library?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing
        ) { location in
            Button("Remove from Library", role: .destructive) { Task { await app.removeLocation(location) } }
        } message: { location in
            Text("\(location.sampleCount.formatted()) samples that are only found here leave the library, with their tags. The audio files are not touched.")
        }
    }

    private var busy: Bool { app.isScanning || app.isIndexing || app.isRetagging }

    private var progressText: String? {
        if let retag = app.retagProgress { return "Retagging \(retag.done.formatted()) of \(retag.total.formatted())…" }
        if app.isScanning { return "Scanning…" }
        return nil
    }
}

private struct LocationRow: View {
    @Environment(AppModel.self) private var app
    let location: LocationInfo
    let edit: () -> Void
    let review: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(location.name, systemImage: "folder")
                Spacer()
                Text("\(location.sampleCount.formatted()) samples").foregroundStyle(.secondary)
            }
            Text(location.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if !location.tagging.extraTags.isEmpty {
                Text("Adds: " + location.tagging.extraTags.joined(separator: ", ")).font(.caption)
            }
            if !location.tagging.rules.isEmpty {
                Text("Ignores \(location.tagging.rules.count) \(location.tagging.rules.count == 1 ? "pattern" : "patterns")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Edit…", action: edit)
                Button("Multisamples…", action: review)
                Button("Rescan") { Task { await app.rescan(location) } }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: location.path)])
                }
                Button("Remove…", role: .destructive, action: remove)
            }
            .controlSize(.small)
            .disabled(app.isScanning || app.isIndexing || app.isRetagging)
        }
        .padding(.vertical, 2)
    }
}

// MARK: Rules

/// A list of blacklist rules with a kind and a pattern each.
struct TagRulesEditor: View {
    @Binding var rules: [TagRule]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rules.indices, id: \.self) { index in
                HStack {
                    Picker("Kind", selection: $rules[index].kind) {
                        Text("Text").tag(TagRule.Kind.text)
                        Text("Pattern (* ?)").tag(TagRule.Kind.glob)
                        Text("Regular expression").tag(TagRule.Kind.regex)
                    }
                    .labelsHidden().frame(width: 170)
                    TextField("Tag or pattern", text: $rules[index].pattern)
                    Button { rules.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove this rule")
                }
                if let message = rules[index].validationMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            Button { rules.append(TagRule(kind: .text, pattern: "")) } label: { Label("Add Rule", systemImage: "plus") }
                .buttonStyle(.borderless)
        }
    }
}

private struct GlobalRulesEditor: View {
    @Environment(AppModel.self) private var app
    @State private var draft: [TagRule] = []
    @State private var count = 0

    private var cleaned: [TagRule] {
        draft.filter { !$0.pattern.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    private var valid: Bool { cleaned.allSatisfy { $0.validationMessage == nil } }
    private var changed: Bool { cleaned != app.globalTagRules }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TagRulesEditor(rules: $draft)
            if changed {
                HStack {
                    Button(count > 0 ? "Apply and retag \(count.formatted()) samples" : "Apply") {
                        Task { await app.updateGlobalRules(cleaned) }
                    }
                    .disabled(!valid || app.isScanning || app.isRetagging)
                    Button("Revert") { draft = app.globalTagRules }
                }
            }
        }
        .onAppear { draft = app.globalTagRules }
        .onChange(of: app.globalTagRules) { _, rules in draft = rules }
        .task(id: cleaned) {
            guard valid, changed else { count = 0; return }
            count = await app.retagCount(globalRules: cleaned)
        }
    }
}

// MARK: Add and edit

/// Adds a folder or changes a location's tag settings, with a preview of the tags it would get.
struct LocationEditor: View {
    enum Mode: Identifiable {
        case add(URL)
        case edit(LocationInfo)

        var id: String {
            switch self {
            case .add(let url): return "add " + url.path
            case .edit(let location): return "edit \(location.id)"
            }
        }

        var folder: URL {
            switch self {
            case .add(let url): return url
            case .edit(let location): return URL(fileURLWithPath: location.path)
            }
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let mode: Mode
    @State private var name = ""
    @State private var extraText = ""
    @State private var rules: [TagRule] = []
    @State private var groupRules = MultisampleRules()
    @State private var preview: TagPreview?
    @State private var previewError: String?
    @State private var filter = ""
    @State private var retagCount = 0
    @State private var dropRareUpTo = 4
    @State private var reviewing = false

    private var tagging: LocationTagging {
        LocationTagging(
            extraTags: extraText.split(separator: ",").map(String.init),
            rules: rules.filter { !$0.pattern.trimmingCharacters(in: .whitespaces).isEmpty })
    }
    private var cleanedGroupRules: MultisampleRules {
        MultisampleRules(
            groupByDefault: groupRules.groupByDefault,
            overrides: groupRules.overrides.compactMap { item in
                let folder = item.folder.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return folder.isEmpty ? nil : MultisampleRules.Override(folder: folder, group: item.group)
            })
    }
    private var valid: Bool { tagging.rules.allSatisfy { $0.validationMessage == nil } }

    private var rows: [TagPreview.Row] {
        guard let preview else { return [] }
        let all = (try? preview.rows(global: app.globalTagRules, location: tagging.rules)) ?? []
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? all : all.filter { $0.tag.contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(mode.folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            TextField("Name", text: $name, prompt: Text("e.g. 909, Mini Moog"))

            // Only this part scrolls, so the buttons stay in the window however many rules are added.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Extra tags").font(.subheadline)
                        TextField("e.g. drumhaus, acoustic", text: $extraText)
                        Text("Added to every sample in this folder. Separate them with commas. Leave empty for none.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ignored tags in this folder").font(.subheadline)
                        TagRulesEditor(rules: $rules)
                    }

                    if case .add = mode { rareTagsSection }

                    multisampleSection

                    previewSection
                }
                .padding(.trailing, 12)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(primaryTitle) { Task { await commit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid || !canCommit)
            }
        }
        .padding(20)
        .frame(width: 680)
        .frame(minHeight: 600, idealHeight: 780)
        .task { await load() }
        .task(id: tagging) { await updateCount() }
    }

    private var title: String {
        switch mode {
        case .add: return "Add Location"
        case .edit: return "Edit Location"
        }
    }

    private var primaryTitle: String {
        switch mode {
        case .add: return "Import"
        case .edit: return retagCount > 0 ? "Apply and retag \(retagCount.formatted()) samples" : "Save"
        }
    }

    private var canCommit: Bool {
        if case .edit(let location) = mode {
            return name != location.name || tagging != location.tagging || cleanedGroupRules != location.multisampleRules || retagCount > 0
        }
        return !(app.isScanning || app.isIndexing || app.isRetagging)
    }

    private var rareTagsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rare tags").font(.subheadline)
            Stepper(value: $dropRareUpTo, in: 0...1000) {
                Text(dropRareUpTo == 0 ? "Do not drop tags by how few samples have them" : "Drop tags that \(dropRareUpTo) or fewer samples have")
            }
            Text("After the import, tags that fewer than 1% of the new samples have are dropped as well. Extra tags and tags you add by hand stay.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var multisampleSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Multisamples").font(.subheadline)
            Toggle("Show one instrument sampled at several pitches as one row", isOn: $groupRules.groupByDefault)
            ForEach(groupRules.overrides.indices, id: \.self) { index in
                HStack {
                    Picker("Folders", selection: $groupRules.overrides[index].group) {
                        Text("Group in").tag(true)
                        Text("Don't group in").tag(false)
                    }
                    .labelsHidden().frame(width: 140)
                    TextField("Folder, relative to the location (e.g. Keys/Drums)", text: $groupRules.overrides[index].folder)
                    Button { groupRules.overrides.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove this exception")
                }
            }
            Button {
                groupRules.overrides.append(.init(folder: "", group: !groupRules.groupByDefault))
            } label: { Label("Add Folder Exception", systemImage: "plus") }
                .buttonStyle(.borderless)
            if case .edit(let location) = mode {
                Button("Review Multisamples…") { reviewing = true }.sheet(isPresented: $reviewing) { MultisampleEditorView(location: location) }
            }
            Text("Groups are found from note names in the files (C3, F#2…) and are checked against the root note in the file or by sound. You can turn grouping off in the list's toolbar too.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tags this folder would get").font(.subheadline)
                Spacer()
                if let preview { Text("\(preview.fileCount.formatted()) audio files").font(.caption).foregroundStyle(.secondary) }
                TextField("Filter", text: $filter).frame(width: 140).textFieldStyle(.roundedBorder)
            }
            if let previewError {
                Text(previewError).foregroundStyle(.red)
            } else if preview == nil {
                HStack { ProgressView().controlSize(.small); Text("Reading file names…").foregroundStyle(.secondary) }
            } else {
                Table(rows) {
                    TableColumn("Tag") { row in
                        let ignored = row.blockedBy != nil
                        Text(row.tag).strikethrough(ignored).foregroundStyle(ignored ? .secondary : .primary)
                    }.width(min: 90, ideal: 140)
                    TableColumn("Files") { Text($0.count.formatted()).font(.sondrMono(size: 12)) }.width(60)
                    TableColumn("Example") { Text($0.example).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary) }
                    TableColumn("") { row in
                        if let rule = row.blockedBy {
                            Text(row.isGlobal ? "Ignored for all" : "Ignored here").font(.caption).foregroundStyle(.secondary)
                                .help("Rule: \(rule.pattern)")
                        } else {
                            Button("Ignore") { rules.append(TagRule(kind: .text, pattern: row.tag)) }
                                .buttonStyle(.borderless).font(.caption)
                        }
                    }.width(100)
                }
                .frame(minHeight: 160)
                Text("Extra tags are not listed. Ignored tags are shown crossed out and will not be given.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        switch mode {
        case .add(let url): name = url.lastPathComponent
        case .edit(let location): name = location.name
        }
        if case .edit(let location) = mode {
            extraText = location.tagging.extraTags.joined(separator: ", ")
            rules = location.tagging.rules
            groupRules = location.multisampleRules
        }
        do {
            preview = try await app.previewTags(of: mode.folder)
        } catch is CancellationError {
        } catch {
            previewError = error.localizedDescription
        }
    }

    private func updateCount() async {
        guard case .edit(let location) = mode, valid else { return }
        retagCount = await app.retagCount(for: location, new: tagging)
    }

    private func commit() async {
        let tagging = tagging
        let groupRules = cleanedGroupRules
        let dropRareUpTo = dropRareUpTo
        let name = name
        switch mode {
        case .add(let url):
            dismiss()
            // The untouched default must not overwrite the custom name of a folder that is already a location.
            let given = name == url.lastPathComponent ? nil : name
            await app.addLocation(url, tagging: tagging, multisampleRules: groupRules, dropRareTagsUpTo: dropRareUpTo, name: given)
        case .edit(let location):
            dismiss()
            if name != location.name { await app.renameLocation(location, to: name) }
            if tagging != location.tagging || retagCount > 0 { await app.updateLocation(location, tagging: tagging) }
            if groupRules != location.multisampleRules { await app.updateMultisampleRules(location, rules: groupRules) }
        }
    }
}
