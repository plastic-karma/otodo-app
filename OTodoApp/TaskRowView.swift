import Foundation
import OTodoCore
import SwiftUI

struct TaskRowView: View {
    let task: TodoTask
    let workflowState: WorkflowState?
    let today: String
    let isCompletionDisabled: Bool
    let onOpen: () -> Void
    let onToggleCompletion: () -> Void
    var isSelected: Bool? = nil
    var ancestry: String? = nil
    var hierarchyDepth: Int = 0
    var rowIdentifier: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Button(action: onToggleCompletion) {
                statusMark
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isCompletionDisabled)
            .accessibilityLabel(
                isSelected.map { "\($0 ? "Deselect" : "Select") \(task.name)" }
                    ?? (workflowState?.isTerminal == true ? "Reopen \(task.name)" :
                        task.recurrence == nil ? "Complete \(task.name)" : "Complete occurrence of \(task.name)")
            )
            .accessibilityHint(
                isSelected == nil && workflowState?.isTerminal != true && task.recurrence != nil
                    ? "Schedules the next occurrence and keeps this todo open"
                    : ""
            )
            .accessibilityValue(isSelected.map { $0 ? "Selected" : "Not selected" }
                ?? (workflowState?.name ?? task.state))
            .accessibilityIdentifier(
                isSelected == nil
                    ? "task-toggle-completion-\(task.id.rawValue)"
                    : "task-select-\(task.id.rawValue)"
            )
            .padding(.top, 2)

            Button(action: onOpen) {
                TaskRowLabel(
                    name: task.name, dueDate: task.dueDate, dueTime: task.dueTime,
                    isRecurring: task.recurrence != nil,
                    projectSlugs: task.projectSlugs, tags: task.tags,
                    workflowState: workflowState, today: today, ancestry: ancestry
                )
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .labelStyle(.titleAndIcon)
            .disabled(isSelected != nil && isCompletionDisabled)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityDescription)
            .accessibilityHint(
                isSelected == nil
                    ? "Opens the todo editor; swipe right or touch and hold for task actions"
                    : "Selects this todo for bulk rescheduling"
            )
            .accessibilityIdentifier(rowIdentifier ?? "task-row-\(task.id.rawValue)")
            .accessibilityAddTraits(isSelected == true ? .isSelected : [])
        }
        .accessibilityElement(children: .contain)
    }


    private var statusMark: some View {
        ZStack {
            Circle()
                .fill(
                    isSelected == true
                        ? OTodoTheme.accent
                        : workflowState?.isTerminal == true ? OTodoTheme.mint : stateColor.opacity(0.10)
                )
            Circle()
                .strokeBorder(stateColor, lineWidth: 1.5)

            if isSelected == true || (isSelected == nil && workflowState?.isTerminal == true) {
                Image(systemName: "checkmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
            } else if isSelected == nil, workflowState?.isInProgress == true {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(stateColor)
            }
        }
        .frame(width: 21, height: 21)
        .accessibilityHidden(true)
    }

    private var stateColor: Color {
        workflowState?.isTerminal == true ? OTodoTheme.mint : OTodoTheme.accent
    }


    private var accessibilityDescription: String {
        var values = [task.name, "State: \(workflowState?.name ?? task.state)"]
        if let ancestry { values.append(ancestry) }
        if hierarchyDepth > 0 { values.append("Hierarchy level \(hierarchyDepth)") }
        if workflowState?.isTerminal == true {
            values.append("Terminal state")
        }
        if task.recurrence != nil {
            values.append(workflowState?.isTerminal == true ? "Series finished" : "Recurring todo")
        }
        if let dueDate = task.dueDate {
            let timeSuffix = task.dueTime.map { " at \($0.rawValue)" } ?? ""
            values.append("Due: \(dueDate.rawValue)\(timeSuffix)")
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

private struct TaskRowLabel: View {
    @Environment(\.locale) private var locale
    let name: String
    let dueDate: CivilDate?
    let dueTime: CivilTime?
    let isRecurring: Bool
    let projectSlugs: [String]
    let tags: [String]
    let workflowState: WorkflowState?
    let today: String
    let ancestry: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.body.weight(workflowState?.isTerminal == true ? .regular : .medium))
                .foregroundStyle(workflowState?.isTerminal == true ? Color.secondary : Color.primary)
                .strikethrough(workflowState?.isTerminal == true)
                .frame(maxWidth: .infinity, alignment: .leading)

            let due = duePresentation
            let context = contextPresentation
            if due != nil || context != nil || isRecurring || workflowState?.isInProgress == true {
                HStack(spacing: 8) {
                    if let due {
                        Text(due.label)
                            .foregroundStyle(due.color)
                            .layoutPriority(1)
                    }
                    if let workflowState, workflowState.isInProgress {
                        if due != nil {
                            Text("·")
                                .accessibilityHidden(true)
                        }
                        Text(workflowState.name)
                            .foregroundStyle(OTodoTheme.accent)
                    }
                    if isRecurring {
                        Image(systemName: "repeat")
                            .accessibilityHidden(true)
                    }
                    if let context {
                        if due != nil || workflowState?.isInProgress == true {
                            Text("·")
                                .accessibilityHidden(true)
                        }
                        Label(context.label, systemImage: context.icon)
                            .truncationMode(.tail)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }

    private var duePresentation: (label: LocalizedStringKey, color: Color)? {
        guard let dueDate else { return nil }
        let date = formattedDate(dueDate.rawValue)
        let time = dueTime.map { formattedTime($0) }
        if workflowState?.isTerminal == true {
            return (time.map { "\(date) · \($0)" } ?? "\(date)", .secondary)
        }
        if dueDate.rawValue < today {
            return (time.map { "Overdue · \(date) · \($0)" } ?? "Overdue · \(date)", .red)
        }
        if dueDate.rawValue == today {
            if let dueTime,
               let currentTime,
               dueTime < currentTime
            {
                return ("Overdue · \(time ?? dueTime.rawValue)", .red)
            }
            return (time.map { "Today · \($0)" } ?? "Today", OTodoTheme.accent)
        }
        return (time.map { "\(date) · \($0)" } ?? "\(date)", OTodoTheme.accent)
    }

    private var contextPresentation: (label: String, icon: String)? {
        if let ancestry {
            return (ancestry, "arrow.turn.down.right")
        }
        if let project = projectSlugs.first {
            let name = project.replacingOccurrences(of: "-", with: " ").capitalized(with: locale)
            let remainder = projectSlugs.count - 1
            return (remainder > 0 ? "\(name) +\(remainder)" : name, "folder")
        }
        if let tag = tags.first {
            let remainder = tags.count - 1
            return (remainder > 0 ? "\(tag) +\(remainder)" : tag, "number")
        }
        return nil
    }

    private func formattedDate(_ value: String) -> String {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return value }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        guard let date = calendar.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
        ) else {
            return value
        }
        return date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
    }

    private func formattedTime(_ value: CivilTime) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        guard let date = calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: 2000,
                month: 1,
                day: 1,
                hour: value.hour,
                minute: value.minute
            )
        ) else {
            return value.rawValue
        }
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
    }

    private var currentTime: CivilTime? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let components = calendar.dateComponents([.hour, .minute], from: .now)
        guard let hour = components.hour, let minute = components.minute else {
            return nil
        }
        return try? CivilTime(rawValue: String(format: "%02d:%02d", hour, minute))
    }
}
