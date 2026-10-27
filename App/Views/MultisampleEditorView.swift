import SondrCore
import SwiftUI

/// Edits the multisample groups of one location by hand. Every edit makes the group manual, so a rescan leaves it alone.
struct MultisampleEditorView: View {
    /// What the sample picker does with the samples: start a group, or join the one with this id.
    private enum Pick: Identifiable {
        case new
        case add(MultisampleGroups.Info)

        var id: Int64 {
            switch self {
            case .new: return 0
            case .add(let group): return group.id
            }
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let location: LocationInfo
    @State private var groups: [MultisampleGroups.Info] = []
    @State private var selected: Int64?
    @State private var members: [SampleRow] = []
    @State private var picking: Pick?
    @State private var renaming = false
    @State private var nameDraft = ""

    private var group: MultisampleGroups.Info? { groups.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Multisamples in \(location.name)").font(.headline)
            HSplitView {
                List(groups, selection: $selected) { info in
                    HStack {
                        Text(info.name).lineLimit(1)
                        if info.manual { Text("manual").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Text(summary(info)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(info.id)
                }
                .frame(minWidth: 240)
                .overlay { if groups.isEmpty { Text("No groups yet").foregroundStyle(.secondary) } }
                memberList.frame(minWidth: 320)
            }
            .frame(minHeight: 280)
            HStack {
                Button("New Group…") { picking = .new }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 460)
        .task { await reload() }
        .onChange(of: selected) { Task { await reload() } }
        .sheet(item: $picking) { pick in
            switch pick {
            case .new:
                SamplePicker(location: location, title: "New group") { name, ids in
                    await edit { _ = try await MultisampleGroups.create(database: $0, locationID: location.id, name: name, sampleIDs: ids) }
                }
            case .add(let group):
                SamplePicker(location: location, title: "Add to “\(group.name)”", name: nil) { _, ids in
                    await edit { try await MultisampleGroups.addMembers(database: $0, groupID: group.id, sampleIDs: ids) }
                }
            }
        }
        .alert("Rename group", isPresented: $renaming) {
            TextField("Name", text: $nameDraft)
            Button("Rename") {
                if let id = selected { Task { await edit { try await MultisampleGroups.rename(database: $0, groupID: id, name: nameDraft) } } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var memberList: some View {
        if let group {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(group.name).font(.subheadline.bold()).lineLimit(1)
                    Spacer()
                    Button("Rename…") { nameDraft = group.name; renaming = true }
                    Button("Add Samples…") { picking = .add(group) }
                    Button("Ungroup", role: .destructive) {
                        Task { await edit { try await MultisampleGroups.delete(database: $0, groupID: group.id) } }
                    }
                    .help("Dissolve the group; its samples become single samples")
                }
                .controlSize(.small)
                List(members) { member in
                    HStack {
                        let isRepresentative = member.id == group.representativeID
                        Button {
                            Task { await edit { try await MultisampleGroups.setRepresentative(database: $0, groupID: group.id, sampleID: member.id) } }
                        } label: {
                            Image(systemName: isRepresentative ? "star.fill" : "star")
                                .foregroundStyle(isRepresentative ? Color.yellow : .secondary)
                        }
                        .buttonStyle(.borderless).help(isRepresentative ? "Representative" : "Make representative")
                        Text(member.filename).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if let label = member.multisample?.pitchLabel { Text(label).font(.caption).foregroundStyle(.secondary) }
                        Button {
                            Task { await edit { try await MultisampleGroups.removeMembers(database: $0, groupID: group.id, sampleIDs: [member.id]) } }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove from the group")
                    }
                }
            }
        } else {
            Text("Select a group").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summary(_ info: MultisampleGroups.Info) -> String {
        info.lowLabel.isEmpty ? "\(info.size) samples" : "\(info.size) · \(info.lowLabel)–\(info.highLabel)"
    }

    private func edit(_ change: (LibraryDatabase) async throws -> Void) async {
        await app.editGroups(change)
        await reload()
    }

    private func reload() async {
        groups = await app.groups(in: location)
        if let selected, !groups.contains(where: { $0.id == selected }) { self.selected = nil }
        members = if let selected { await app.members(ofGroup: selected) } else { [] }
    }
}

/// Searchable multi-select of the location's ungrouped samples. With a `name` field it starts a new group.
private struct SamplePicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let location: LocationInfo
    let title: String
    /// Nil when the samples join an existing group.
    var name: String? = ""
    let apply: (String, [Int64]) async -> Void
    @State private var nameDraft = ""
    @State private var search = ""
    @State private var samples: [SampleRow] = []
    @State private var picked = Set<Int64>()

    init(location: LocationInfo, title: String, name: String? = "", apply: @escaping (String, [Int64]) async -> Void) {
        self.location = location
        self.title = title
        self.name = name
        self.apply = apply
    }

    private var canApply: Bool {
        !picked.isEmpty && (name == nil || !nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if name != nil { TextField("Group name", text: $nameDraft) }
            TextField("Search samples without a group", text: $search).textFieldStyle(.roundedBorder)
            List(samples, selection: $picked) { sample in
                HStack {
                    Text(sample.filename).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if let label = sample.multisample?.pitchLabel { Text(label).font(.caption).foregroundStyle(.secondary) }
                }
                .tag(sample.id)
            }
            .overlay { if samples.isEmpty { Text("No ungrouped samples").foregroundStyle(.secondary) } }
            HStack {
                Text("\(picked.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(name == nil ? "Add" : "Create") {
                    Task {
                        await apply(nameDraft, Array(picked))
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(!canApply)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .task(id: search) {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            if !Task.isCancelled { samples = await app.ungroupedSamples(in: location, matching: search) }
        }
    }
}
