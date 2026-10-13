import Foundation
import OTodoCore
import SwiftUI

struct RelativeDueDateField: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private static let helpText: LocalizedStringKey =
        "Set from now using minutes, hours, days, weeks, months, or years."
    private static let invalidText =
        "Use a phrase such as “in 3 days” or “in 6 hours”."

    let accessibilityIdentifierPrefix: String
    let onPendingChange: (Bool) -> Void
    let onApply: (Date, RelativeDueDateExpression.Unit) -> Void

    @State private var text = ""
    @State private var parsedExpression: RelativeDueDateExpression?
    @State private var resolutionError: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                TextField("in 3 days", text: textBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(apply)
                    .focused($isFocused)
                    .accessibilityLabel("Relative due date")
                    .accessibilityIdentifier("\(accessibilityIdentifierPrefix)-date")
                    .frame(minHeight: 44)

                Button("Apply") {
                    apply()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(parsedExpression == nil)
                .accessibilityIdentifier("\(accessibilityIdentifierPrefix)-apply")
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Invalid relative due date. \(validationMessage)")
            } else {
                Text(Self.helpText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                let wasPending = hasPendingInput
                text = newValue
                let isPending = !newValue
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                parsedExpression = isPending
                    ? (try? RelativeDueDateExpression(newValue))
                    : nil
                resolutionError = nil
                if isPending != wasPending {
                    onPendingChange(isPending)
                }
            }
        )
    }

    private var hasPendingInput: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var validationMessage: String? {
        if let resolutionError {
            return resolutionError
        }
        return hasPendingInput && parsedExpression == nil ? Self.invalidText : nil
    }

    private func apply() {
        guard let parsedExpression else { return }
        do {
            let resolved = try parsedExpression.resolve(calendar: TaskSchedule.calendar)
            let resolvedDate = TaskSchedule.date(from: resolved.date, time: resolved.time)
            isFocused = false
            text = ""
            self.parsedExpression = nil
            resolutionError = nil
            onPendingChange(false)
            onApply(resolvedDate, parsedExpression.unit)
        } catch {
            resolutionError = error.localizedDescription
        }
    }
}

/// Edits only caller-owned draft fields. The caller remains the Save/Cancel boundary.
struct TaskScheduleFields: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var date: Date
    @Binding var time: Date
    @Binding var dateChange: TaskSchedule.FieldChange
    @Binding var timeChange: TaskSchedule.FieldChange
    @Binding var hasPendingRelativeDueDate: Bool
    let isBulk: Bool
    let identifierPrefix: String
    let dateIdentifierPrefix: String
    let helpText: LocalizedStringResource
    let onRelativeApply: () -> Void
    @State private var isCustomExpanded = false
    @State private var isRelativeExpanded = false

    var body: some View {
        if isBulk {
            Picker("Due dates", selection: $dateChange) {
                Text("Keep existing dates").tag(TaskSchedule.FieldChange.preserve)
                Text("Set date").tag(TaskSchedule.FieldChange.set)
                Text("Remove dates").tag(TaskSchedule.FieldChange.clear)
            }
            .accessibilityIdentifier("\(identifierPrefix)-date-change")
        }

        let columns = dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            quickChoice("Today", days: 0, identifier: "today")
            quickChoice("Tomorrow", days: 1, identifier: "tomorrow")
            quickChoice("Next week", days: 7, identifier: "next-week")
                .accessibilityHint("Seven calendar days from today")
            Button {
                dateChange = .set
                isCustomExpanded.toggle()
            } label: {
                Label("Custom", systemImage: "calendar")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(OTodoChipStyle(isSelected: isCustomExpanded))
            .accessibilityIdentifier("\(identifierPrefix)-custom")
            .accessibilityValue(isCustomExpanded ? "Expanded" : "Collapsed")
        }

        if dateChange == .set {
            if isCustomExpanded {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .environment(\.calendar, TaskSchedule.calendar)
                    .accessibilityIdentifier("\(dateIdentifierPrefix)-date-picker")
            } else {
                LabeledContent("Date") {
                    Text(date, format: .dateTime.weekday().month().day().year())
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !isBulk {
                Button("Clear date", role: .destructive) {
                    dateChange = .clear
                    isCustomExpanded = false
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("\(identifierPrefix)-clear-date")
            }
        }

        if dateChange != .clear {
            if isBulk {
                Picker("Due times", selection: $timeChange) {
                    Text("Keep existing times").tag(TaskSchedule.FieldChange.preserve)
                    Text("Set time").tag(TaskSchedule.FieldChange.set)
                    Text("Remove times").tag(TaskSchedule.FieldChange.clear)
                }
                .accessibilityIdentifier("\(identifierPrefix)-time-change")
            } else {
                Toggle("Include time", isOn: Binding(
                    get: { timeChange == .set },
                    set: { timeChange = $0 ? .set : .clear }
                ))
                .accessibilityIdentifier("\(dateIdentifierPrefix)-time-toggle")
            }
            if timeChange == .set {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    .environment(\.calendar, TaskSchedule.calendar)
                    .accessibilityIdentifier("\(dateIdentifierPrefix)-time-picker")
            }
        }

        DisclosureGroup(isExpanded: $isRelativeExpanded) {
            RelativeDueDateField(
                accessibilityIdentifierPrefix: "\(identifierPrefix)-relative-due",
                onPendingChange: { hasPendingRelativeDueDate = $0 },
                onApply: { resolvedDate, unit in
                    if !isBulk || unit == .minute || unit == .hour {
                        date = resolvedDate
                        time = resolvedDate
                        timeChange = .set
                    } else {
                        date = TaskSchedule.replacingDay(of: date, with: resolvedDate)
                    }
                    dateChange = .set
                    onRelativeApply()
                }
            )
        } label: {
            Label("Relative date", systemImage: "text.cursor")
        }
        .disclosureGroupStyle(TaskEditorDisclosureStyle(
            identifier: "\(identifierPrefix)-relative-due-disclosure",
            beforeToggle: {}
        ))

        DisclosureGroup("Schedule help") {
            Text(helpText)
                .font(.footnote)
                .foregroundStyle(OTodoTheme.secondaryText)
            Text("Next week means seven calendar days from today. Choosing a day keeps your time setting.")
                .font(.footnote)
                .foregroundStyle(OTodoTheme.secondaryText)
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("\(identifierPrefix)-schedule-help")
    }

    private func quickChoice(
        _ title: LocalizedStringKey, days: Int, identifier: String
    ) -> some View {
        Button {
            date = TaskSchedule.replacingDay(of: date, with: TaskSchedule.quickDate(daysFromToday: days))
            dateChange = .set
            isCustomExpanded = false
        } label: {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(OTodoChipStyle())
        .accessibilityIdentifier("\(identifierPrefix)-\(identifier)")
    }
}
