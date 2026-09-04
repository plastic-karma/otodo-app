import Foundation
import OTodoCore
import SwiftUI

struct TaskRowView: View {
    let task: TodoTask
    let workflowState: WorkflowState?
    let today: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            statusMark
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(task.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .strikethrough(workflowState?.isTerminal == true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(workflowState?.name ?? task.state)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(stateColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(stateColor.opacity(0.11), in: Capsule())
                }

                if let duePresentation {
                    Label(duePresentation.label, systemImage: "calendar")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(duePresentation.color)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(duePresentation.color.opacity(0.11), in: Capsule())
                }

                if !task.projectSlugs.isEmpty || !task.tags.isEmpty {
                    HStack(spacing: 12) {
                        if !task.projectSlugs.isEmpty {
                            Label(projectDescription, systemImage: "folder.fill")
                        }
                        if !task.tags.isEmpty {
                            Label(tagDescription, systemImage: "tag.fill")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
        }
        .padding(16)
        .background(
            OTodoTheme.raisedCard,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.045))
        }
        .shadow(color: .black.opacity(0.055), radius: 10, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                .strokeBorder(stateColor, lineWidth: 2)

            if workflowState?.isTerminal == true {
                Image(systemName: "checkmark")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
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
