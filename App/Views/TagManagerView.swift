import SondrCore
import SwiftUI

/// All tags with their use counts: rename, merge into another tag, delete.
struct TagManagerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [TagCount] = []
    @State private var query = ""
    @State private var selected: String?
    @State private var renaming: String?
    @State private var merging: String?
    @State private var text = ""
    @State private var confirmingDelete = false

    private var shown: [TagCount] {
        query.isEmpty ? tags : tags.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags").font(.headline)
            TextField("Filter tags", text: $query).textFieldStyle(.roundedBorder)
            Table(shown, selection: $selected) {
                TableColumn("Tag", value: \.name)
                TableColumn("Samples") { Text("\($0.count)").monospacedDigit() }.width(80)
            }
            .frame(minHeight: 260)
            HStack {
                Button("Rename…") { text = selected ?? ""; renaming = selected }
                Button("Merge Into…") { text = ""; merging = selected }
                Button("Delete…", role: .destructive) { confirmingDelete = true }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .disabled(selected == nil)
            Text("Renaming or merging an auto tag does not change future scans: new files whose path contains the old word get the old tag again.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460, height: 460)
        .task { await reload() }
        .alert("Rename “\(renaming ?? "")”", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New name", text: $text)
            Button("Rename") {
                if let old = renaming { Task { await app.renameTag(old, to: text); await reload() } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Merge “\(merging ?? "")” into", isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })) {
            TextField("Existing or new tag", text: $text)
            Button("Merge") {
                if let source = merging { Task { await app.mergeTag(source, into: text); await reload() } }
                merging = nil
            }
            Button("Cancel", role: .cancel) { merging = nil }
        }
        .alert("Tags", isPresented: Binding(get: { app.message != nil }, set: { if !$0 { app.message = nil } })) {
            Button("OK") { app.message = nil }
        } message: { Text(app.message ?? "") }
        .confirmationDialog("Delete “\(selected ?? "")” from all samples?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) {
                if let name = selected { Task { await app.deleteTag(name); selected = nil; await reload() } }
            }
        }
    }

    private func reload() async { tags = await app.allTags() }
}
