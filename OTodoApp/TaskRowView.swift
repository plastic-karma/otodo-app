import OTodoCore
import SwiftUI

struct TaskRowView: View {
    let task: TodoTask
    let workflowState: WorkflowState?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Label(workflowState?.name ?? task.state, systemImage: stateSymbol)

                if workflowState?.isTerminal == true {
                    Text("Terminal")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.14), in: Capsule())
                }

                if let dueDate = task.dueDate {
                    Label(dueDate.rawValue, systemImage: "calendar")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            if !task.projectSlugs.isEmpty || !task.tags.isEmpty {
                Text(metadataDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var stateSymbol: String {
        workflowState?.isTerminal == true ? "checkmark.circle" : "circle.dotted"
    }

    private var metadataDescription: String {
        let projects = task.projectSlugs.map { "Project: \($0)" }
        let tags = task.tags.map { "#\($0)" }
        return (projects + tags).joined(separator: "  ")
    }

    private var accessibilityDescription: String {
        var values = [task.name, "State: \(workflowState?.name ?? task.state)"]
        if workflowState?.isTerminal == true {
            values.append("Terminal state")
        }
        if let dueDate = task.dueDate {
            values.append("Due: \(dueDate.rawValue)")
        }
        if !task.projectSlugs.isEmpty {
            values.append("Projects: \(task.projectSlugs.joined(separator: ", "))")
        }
        if !task.tags.isEmpty {
            values.append("Tags: \(task.tags.joined(separator: ", "))")
        }
        return values.joined(separator: ". ")
    }
}
