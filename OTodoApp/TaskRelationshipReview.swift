import OTodoCore
import SwiftUI

struct TaskRelationshipReview: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    @State private var editingTask: RepairPresentation?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Relationships are checked across the whole workspace, not just your current filter. Edit a child's Parent to reparent it or choose No Parent to detach it. Completing a parent completes its active descendants; schedules and reopening remain task-specific.")
                }
                Section("Workspace relationship issues") {
                    if model.hierarchy.issues.isEmpty {
                        Text("No workspace relationship issues")
                    }
                    ForEach(model.hierarchy.issues, id: \.reviewID) { issue in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(issue.message)
                            Text(issue.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                            repairButton(for: issue.taskID)
                        }
                    }
                }
                Section("Relationship changes withheld from sync") {
                    if model.relationshipBlocks.isEmpty {
                        Text("No relationship changes withheld")
                    }
                    ForEach(model.relationshipBlocks, id: \.reviewID) { block in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(block.message)
                            Text(block.path).font(.caption.monospaced())
                            Text(block.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                            ForEach(block.relatedTaskIDs, id: \.self) { id in repairButton(for: id) }
                        }
                    }
                }
                Section {
                    Text("Withheld changes remain saved on this device. They are not same-file merge conflicts. Resolve any related file conflict using Sync Review, then refresh to recompute which changes can publish safely.")
                }
            }
            .navigationTitle("Relationships")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("relationship-review")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $editingTask) { presentation in
                let task = presentation.task
                if let configuration = model.configuration {
                    TaskEditorView(
                        draft: TaskEditorDraft(task: task),
                        configuration: configuration,
                        projectChoices: model.projectChoices,
                        tagChoices: model.tagChoices,
                        hierarchy: model.hierarchy,
                        workspaceTasks: model.tasks,
                            attachmentModel: model
                    ) { draft in
                        await model.updateTask(id: task.id, draft: draft)
                        return model.errorMessage
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func repairButton(for id: TaskID) -> some View {
        if let task = model.hierarchy.task(for: id) {
            Button {
                editingTask = RepairPresentation(task: task)
            } label: {
                VStack(alignment: .leading) {
                    Text("Edit \(task.name)")
                    Text(id.rawValue).font(.caption.monospaced())
                }
            }
            .accessibilityIdentifier("relationship-repair-\(id.rawValue)")
        } else {
            Text("Unavailable or ambiguous task · \(id.rawValue). Repair the source record, then refresh.")
                .font(.caption)
        }
    }
}

private struct RepairPresentation: Identifiable {
    let task: TodoTask
    var id: TaskID { task.id }
}

private struct HierarchyIssueReviewID: Hashable {
    let taskID: TaskID
    let code: String
}

private extension TaskHierarchyIssue {
    var reviewID: HierarchyIssueReviewID {
        HierarchyIssueReviewID(taskID: taskID, code: code)
    }
}

private struct RelationshipBlockReviewID: Hashable {
    let path: String
    let code: String
    let reason: String
}

private extension TaskRelationshipBlock {
    var reviewID: RelationshipBlockReviewID {
        // Sync can withhold the same path/code for distinct local and publish reasons.
        // Match its diagnostic identity without including the changing repair targets.
        RelationshipBlockReviewID(path: path, code: code, reason: message)
    }
}
