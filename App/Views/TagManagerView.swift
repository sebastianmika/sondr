import SondrCore
import SwiftUI

/// All tags with their use counts: rename, merge into another tag, delete. Merge and delete take several tags.
struct TagManagerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [TagCount] = []
    @State private var query = ""
    @State private var sortOrder = [KeyPathComparator(\TagCount.count, order: .reverse)]
    @State private var selected: Set<String> = []
    @State private var renaming: String?
    @State private var merging: [String]?
    @State private var text = ""
    @State private var confirmingDelete = false

    /// Selected tags that are visible; a tag hidden by the filter or gone after a reload is never acted on.
    private var selectedNames: [String] { shown.map(\.name).filter(selected.contains) }

    private var shown: [TagCount] {
        let matching = query.isEmpty ? tags : tags.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return matching.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags").font(.headline)
            TextField("Filter tags", text: $query).textFieldStyle(.roundedBorder)
            Table(shown, selection: $selected, sortOrder: $sortOrder) {
                TableColumn("Tag", value: \.name)
                TableColumn("Samples", value: \.count) { Text("\($0.count)").font(.sondrMono(size: 12)) }.width(80)
            }
            .frame(minHeight: 260)
            HStack {
                Button("Rename…") { text = selectedNames[0]; renaming = selectedNames[0] }
                    .disabled(selectedNames.count != 1)
                Button("Merge Into…") { text = ""; merging = selectedNames }
                    .disabled(selectedNames.isEmpty)
                Button("Delete…", role: .destructive) { confirmingDelete = true }
                    .disabled(selectedNames.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("Renaming or merging an auto tag does not change future scans: new files whose path contains the old word get the old tag again.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460, height: 460)
        .task { await reload() }
        .alert("Rename “\(renaming ?? "")”", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New name", text: $text)
            Button("Rename") {
                if let old = renaming { Task { await app.renameTag(old, to: text); selected = []; await reload() } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Merge \(mergeTitle) into", isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })) {
            TextField("Existing or new tag", text: $text)
            Button("Merge") {
                if let sources = merging {
                    Task { await app.mergeTags(sources, into: text); selected = []; await reload() }
                }
                merging = nil
            }
            Button("Cancel", role: .cancel) { merging = nil }
        }
        .alert("Tags", isPresented: Binding(get: { app.message != nil }, set: { if !$0 { app.message = nil } })) {
            Button("OK") { app.message = nil }
        } message: { Text(app.message ?? "") }
        .confirmationDialog("Delete \(deleteTitle) from all samples?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                let names = selectedNames
                Task { await app.deleteTags(names); selected = []; await reload() }
            }
        }
    }

    private var mergeTitle: String { title(for: merging ?? []) }
    private var deleteTitle: String { title(for: selectedNames) }

    private func title(for names: [String]) -> String {
        names.count == 1 ? "“\(names[0])”" : "\(names.count) tags"
    }

    private func reload() async { tags = await app.allTags() }
}
