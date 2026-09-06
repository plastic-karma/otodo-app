import OTodoCore
import SwiftUI

struct TaskParentPicker: View {
    @Environment(\.dismiss) private var dismiss
    let hierarchy: TaskHierarchy
    let tasks: [TodoTask]
    let taskID: TaskID?
    @Binding var parentID: TaskID?
    let schemaVersion: Int
    @State private var query = ""

    private var candidates: [TodoTask] {
        var excluded = taskID.map { hierarchy.descendantIDs(of: $0) } ?? []
        if let taskID { excluded.insert(taskID) }
        return tasks.filter {
            !excluded.contains($0.id)
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.id.rawValue.localizedCaseInsensitiveContains(query))
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.rawValue < $1.id.rawValue : order == .orderedAscending
        }
    }

    var body: some View {
        let matches = candidates
        NavigationStack {
            List {
                if schemaVersion != 2 {
                    Section("Store upgrade required") {
                        Text("Subtasks require store schema 2. Ordinary todos still work in this version 1 store.")
                        Text("Stop all clients and sync, safeguard pending work, then run otodo upgrade --to 2 from the store. Refresh this workspace after the upgrade. This app never upgrades automatically.")
                    }
                    .accessibilityIdentifier("parent-upgrade-guidance")
                } else {
                    Section {
                        Button {
                            parentID = nil
                            dismiss()
                        } label: {
                            Label("No Parent", systemImage: parentID == nil ? "checkmark.circle.fill" : "circle")
                        }
                        .accessibilityIdentifier("parent-picker-none")
                        if let parentID {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hierarchy.task(for: parentID)?.name ?? "Missing parent")
                                Text(parentID.rawValue).font(.caption.monospaced())
                                if hierarchy.task(for: parentID) == nil {
                                    Text("This relationship is broken. Choose another parent or No Parent to repair it.")
                                        .foregroundStyle(.red)
                                }
                            }
                            .accessibilityIdentifier("parent-picker-current")
                        }
                    }
                    Section("All workspace todos, including completed") {
                        ForEach(matches, id: \.id) { task in
                            Button {
                                parentID = task.id
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(task.name)
                                        if parentID == task.id { Image(systemName: "checkmark") }
                                    }
                                    Text(task.id.rawValue).font(.caption.monospaced())
                                    Text(task.state).font(.caption).foregroundStyle(.secondary)
                                    let ancestors = hierarchy.ancestorIDs(of: task.id)
                                    if !ancestors.isEmpty {
                                        Text(ancestors.map { hierarchy.task(for: $0)?.name ?? $0.rawValue }.joined(separator: " › "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityIdentifier("parent-candidate-\(task.id.rawValue)")
                        }
                        if matches.isEmpty { Text("No matching eligible parents") }
                    }
                }
            }
            .searchable(text: $query, prompt: "Name or full ID")
            .navigationTitle("Choose Parent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("parent-picker-cancel")
                }
            }
        }
    }
}
