import Foundation

public struct RelativeDueDateExpression: Sendable, Equatable {
    public enum Unit: String, Sendable, Equatable, CaseIterable {
        case minute
        case hour
        case day
        case week
        case month
        case year
    }

    public let amount: Int
    public let unit: Unit

    public init(_ rawValue: String) throws {
        let parts = rawValue.split(whereSeparator: { $0.isWhitespace })
        guard parts.count == 3, parts[0].lowercased() == "in" else {
            throw Self.validationError
        }

        let amountToken = parts[1]
        guard amountToken.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let amount = Int(amountToken),
              amount > 0
        else {
            throw Self.validationError
        }

        let rawUnit = parts[2].lowercased()
        let singularUnit = rawUnit.hasSuffix("s") ? String(rawUnit.dropLast()) : rawUnit
        guard let unit = Unit(rawValue: singularUnit) else {
            throw Self.validationError
        }

        self.amount = amount
        self.unit = unit
    }

    public func resolve(
        from referenceDate: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> (date: CivilDate, time: CivilTime) {
        guard var resolvedDate = calendar.date(
            byAdding: calendarComponent,
            value: amount,
            to: referenceDate
        ) else {
            throw OTodoError.validation(
                field: "relativeDueDate",
                message: "The relative due date is outside the supported calendar range"
            )
        }

        let subminute = calendar.dateComponents([.second, .nanosecond], from: resolvedDate)
        if (subminute.second ?? 0) > 0 || (subminute.nanosecond ?? 0) > 0 {
            guard let roundedDate = calendar.date(byAdding: .minute, value: 1, to: resolvedDate) else {
                throw OTodoError.validation(
                    field: "relativeDueDate",
                    message: "The relative due date is outside the supported calendar range"
                )
            }
            resolvedDate = roundedDate
        }

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: resolvedDate
        )
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let hour = components.hour,
              let minute = components.minute
        else {
            throw OTodoError.validation(
                field: "relativeDueDate",
                message: "The relative due date could not be represented"
            )
        }

        return (
            date: try CivilDate(
                rawValue: String(format: "%04d-%02d-%02d", year, month, day)
            ),
            time: try CivilTime(rawValue: String(format: "%02d:%02d", hour, minute))
        )
    }

    private var calendarComponent: Calendar.Component {
        switch unit {
        case .minute:
            .minute
        case .hour:
            .hour
        case .day:
            .day
        case .week:
            .weekOfYear
        case .month:
            .month
        case .year:
            .year
        }
    }

    private static var validationError: OTodoError {
        OTodoError.validation(
            field: "relativeDueDate",
            message: "Use 'in' followed by a positive number and unit, such as 'in 3 days'"
        )
    }
}
