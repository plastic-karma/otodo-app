import Foundation
import OTodoCore
import SwiftUI

struct TaskRowView: View {
    let task: TodoTask
    let workflowState: WorkflowState?
    let today: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusMark
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(task.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .strikethrough(workflowState?.isTerminal == true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(workflowState?.name ?? task.state)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let duePresentation {
                    Label(duePresentation.label, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(duePresentation.color)
                }

                if !task.projectSlugs.isEmpty || !task.tags.isEmpty {
                    HStack(spacing: 12) {
                        if !task.projectSlugs.isEmpty {
                            Label(projectDescription, systemImage: "folder")
                        }
                        if !task.tags.isEmpty {
                            Text(tagDescription)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var statusMark: some View {
        ZStack {
            Circle()
                .fill(
                    workflowState?.isTerminal == true
                        ? OTodoTheme.mint
                        : stateColor.opacity(0.10)
                )
            Circle()
                .strokeBorder(stateColor, lineWidth: 1.5)

            if workflowState?.isTerminal == true {
                Image(systemName: "checkmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 21, height: 21)
        .accessibilityHidden(true)
    }

    private var stateColor: Color {
        workflowState?.isTerminal == true ? OTodoTheme.mint : OTodoTheme.accent
    }

    private var duePresentation: (label: String, color: Color)? {
        guard let dueDate = task.dueDate else { return nil }
        let formattedDate = formattedDate(dueDate.rawValue)
        let formattedTime = task.dueTime.map { self.formattedTime($0) }
        if dueDate.rawValue < today {
            return (
                ["Overdue", formattedDate, formattedTime].compactMap { $0 }.joined(separator: " · "),
                .red
            )
        }
        if dueDate.rawValue == today {
            if let dueTime = task.dueTime,
               let currentTime,
               dueTime < currentTime
            {
                return ("Overdue · \(formattedTime ?? dueTime.rawValue)", .red)
            }
            if let formattedTime {
                return ("Today · \(formattedTime)", OTodoTheme.coral)
            }
            return ("Today", OTodoTheme.coral)
        }
        return (
            [formattedDate, formattedTime].compactMap { $0 }.joined(separator: " · "),
            OTodoTheme.accent
        )
    }

    private var projectDescription: String {
        task.projectSlugs
            .map { $0.replacingOccurrences(of: "-", with: " ").capitalized }
            .joined(separator: ", ")
    }

    private var tagDescription: String {
        task.tags.map { "#\($0)" }.joined(separator: ", ")
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
        return date.formatted(.dateTime.month(.abbreviated).day())
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
        return date.formatted(date: .omitted, time: .shortened)
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

    private var accessibilityDescription: String {
        var values = [task.name, "State: \(workflowState?.name ?? task.state)"]
        if workflowState?.isTerminal == true {
            values.append("Terminal state")
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
