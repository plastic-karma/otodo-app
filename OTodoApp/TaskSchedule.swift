import Foundation
import OTodoCore

enum TaskSchedule {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    static func date(from civilDate: CivilDate?, time: CivilTime?) -> Date {
        guard let civilDate else { return .now }

        let parts = civilDate.rawValue.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return .now }

        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = time?.hour ?? 12
        components.minute = time?.minute ?? 0
        return calendar.date(from: components) ?? .now
    }

    static func civilDate(from date: Date) -> CivilDate? {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            return nil
        }
        return try? CivilDate(
            rawValue: String(format: "%04d-%02d-%02d", year, month, day)
        )
    }

    static func civilTime(from date: Date) -> CivilTime? {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else {
            return nil
        }
        return try? CivilTime(
            rawValue: String(format: "%02d:%02d", hour, minute)
        )
    }
}
