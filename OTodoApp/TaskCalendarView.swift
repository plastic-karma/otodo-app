import OTodoCore
import SwiftUI

struct TaskCalendarView: View {
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @ScaledMetric(relativeTo: .body) private var minimumDayWidth = 44
    @Binding private var selectedDate: CivilDate?
    @State private var visibleDate: CivilDate

    let tasksByDate: [CivilDate?: [TodoTask]]
    let today: CivilDate

    init(selectedDate: Binding<CivilDate?>, tasksByDate: [CivilDate?: [TodoTask]], today: CivilDate) {
        _selectedDate = selectedDate
        _visibleDate = State(initialValue: selectedDate.wrappedValue ?? today)
        self.tasksByDate = tasksByDate
        self.today = today
    }

    var body: some View {
        let month = TaskCalendarMonth(containing: visibleDate, firstWeekday: calendar.firstWeekday)
        let symbols = dateSymbols

        VStack(spacing: 12) {
            Text("\(symbols.standaloneMonthSymbols[month.month - 1]) \(month.year.formatted(.number.grouping(.never).locale(locale)))")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("calendar-month-title")

            HStack(spacing: 8) {
                Button {
                    select(month.previousMonth)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(month.previousMonth == nil)
                .accessibilityLabel("Previous month")
                .accessibilityIdentifier("calendar-previous-month")

                Spacer(minLength: 0)
                Button {
                    select(today)
                } label: {
                    Text("Today · \(tasksByDate[today]?.count ?? 0)")
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("Today")
                .accessibilityValue(Text("\(tasksByDate[today]?.count ?? 0) tasks"))
                .accessibilityIdentifier("calendar-today")
                Spacer(minLength: 0)

                Button {
                    select(month.nextMonth)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(month.nextMonth == nil)
                .accessibilityLabel("Next month")
                .accessibilityIdentifier("calendar-next-month")
            }
            .foregroundStyle(OTodoTheme.accent)

            // Seven usable columns are retained at large text sizes; narrow screens can scroll.
            ScrollView(.horizontal) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(minimum: minimumDayWidth), spacing: 4), count: 7),
                    spacing: 4
                ) {
                    ForEach(month.weekdays, id: \.self) { weekday in
                        Text(symbols.veryShortStandaloneWeekdaySymbols[weekday - 1])
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .accessibilityLabel(symbols.standaloneWeekdaySymbols[weekday - 1])
                            .accessibilityAddTraits(.isHeader)
                    }
                    ForEach(0 ..< month.leadingBlankCount, id: \.self) { _ in
                        Color.clear
                            .frame(minHeight: 44)
                            .accessibilityHidden(true)
                    }
                    ForEach(month.days, id: \.self) { date in
                        dayButton(date, month: month, symbols: symbols)
                    }
                }
                .containerRelativeFrame(.horizontal) { width, _ in
                    max(width, minimumDayWidth * 7 + 24)
                }
                .padding(.vertical, 2)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .accessibilityIdentifier("calendar-grid")

            Button {
                selectedDate = nil
            } label: {
                Text("No date · \(tasksByDate[nil]?.count ?? 0)")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 8)
                    .foregroundStyle(selectedDate == nil ? Color.white : OTodoTheme.accent)
                    .background(selectedDate == nil ? OTodoTheme.filledAccent : OTodoTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("No date")
            .accessibilityValue(Text("\(tasksByDate[nil]?.count ?? 0) tasks"))
            .accessibilityAddTraits(selectedDate == nil ? .isSelected : [])
            .accessibilityIdentifier("calendar-no-date")
        }
        .buttonStyle(.plain)
        .onChange(of: selectedDate) { _, date in
            // A filter refresh or choosing No date must not reset the browsed month.
            if let date { visibleDate = date }
        }
    }

    private func dayButton(_ date: CivilDate, month: TaskCalendarMonth, symbols: DateFormatter) -> some View {
        let day = Int(date.rawValue.suffix(2))!
        let count = tasksByDate[date]?.count ?? 0
        let isSelected = selectedDate == date
        let isToday = today == date
        let weekday = month.weekdays[(month.leadingBlankCount + day - 1) % 7]
        // Symbol-based labels preserve the stored Gregorian date, including year zero,
        // rather than applying a user's alternate calendar or a historical cutover.
        let fullDate = "\(symbols.standaloneWeekdaySymbols[weekday - 1]), \(symbols.monthSymbols[month.month - 1]) \(day.formatted(.number.locale(locale))), \(month.year.formatted(.number.grouping(.never).locale(locale)))"

        return Button {
            select(date)
        } label: {
            VStack(spacing: 2) {
                Text(day, format: .number.locale(locale))
                    .font(.body.weight(isToday || isSelected ? .bold : .regular).monospacedDigit())
                    .underline(isToday)
                Text(count == 0 ? " " : count > 99 ? "99+" : count.formatted(.number.locale(locale)))
                    .font(.caption2.weight(.medium).monospacedDigit())
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(isSelected ? OTodoTheme.filledAccent : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? Color.white : OTodoTheme.accent, lineWidth: 2)
                        .padding(2)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(isToday ? "\(fullDate), Today" : fullDate))
        .accessibilityValue(Text("\(count) tasks"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("calendar-day-\(date.rawValue)")
    }

    private var dateSymbols: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }

    private func select(_ date: CivilDate?) {
        guard let date else { return }
        visibleDate = date
        selectedDate = date
    }
}
